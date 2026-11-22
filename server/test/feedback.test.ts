import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { escapeMarkdown, issueDescription, issueTitle, LINEAR_API_URL } from "../src/feedback/linear";
import { FEEDBACK_RETRY, retryFeedback, submitFeedback } from "../src/feedback/service";
import { parseFeedback } from "../src/feedback/validate";
import { isDailyRun } from "../src/maintenance";
import { call, device } from "./helpers";

let ipCounter = 0;
/** A fresh /24 per request group so per-network limits don't leak between tests. */
function freshIp(): string {
  ipCounter += 1;
  return `172.16.${ipCounter % 250}.${Math.floor(ipCounter / 250) + 1}`;
}

interface LinearCall {
  authorization: string | null;
  input: { teamId: string; title: string; description: string; labelIds?: string[]; projectId?: string; stateId?: string };
}

let linearCalls: LinearCall[] = [];
let linearResponder: () => Response = () => linearOk("GON-1");
const realFetch = globalThis.fetch;

function linearOk(identifier: string): Response {
  return Response.json({ data: { issueCreate: { success: true, issue: { id: crypto.randomUUID(), identifier } } } });
}

beforeEach(() => {
  linearCalls = [];
  linearResponder = () => linearOk("GON-1");
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    if (request.url !== LINEAR_API_URL) return realFetch(input, init);
    const body = (await request.json()) as { variables: { input: LinearCall["input"] } };
    linearCalls.push({ authorization: request.headers.get("Authorization"), input: body.variables.input });
    return linearResponder();
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

function send(body: unknown, options: { ip?: string; token?: string; raw?: string } = {}) {
  const headers: Record<string, string> = { "Content-Type": "application/json", "CF-Connecting-IP": options.ip ?? freshIp() };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;
  return call("/v1/feedback", { method: "POST", headers, body: options.raw ?? JSON.stringify(body) });
}

const diagnostics = { app: "macos", appVersion: "0.3.0", build: "42", osVersion: "macOS 15.2", deviceModel: "Mac14,2", locale: "de_DE" };

async function row(id: string) {
  return env.DB.prepare("SELECT * FROM feedback WHERE id = ?").bind(id).first<Record<string, unknown>>();
}

describe("POST /v1/feedback", () => {
  it("creates a Linear issue with the kind and feedback labels and clears the stored text", async () => {
    linearResponder = () => linearOk("GON-7");
    const res = await send({ kind: "bug", message: "The sidebar flickers when I rename a folder.", replyEmail: "anna@example.com", includeDiagnostics: true, diagnostics });
    expect(res.status).toBe(201);
    const json = (await res.json()) as { ok: boolean; id: string; status: string };
    expect(json).toMatchObject({ ok: true, status: "sent" });

    expect(linearCalls).toHaveLength(1);
    const [linear] = linearCalls;
    expect(linear!.authorization).toBe("lin_api_test");
    expect(linear!.input.teamId).toBe("team-test");
    expect(linear!.input.labelIds).toEqual(["label-bug", "label-feedback"]);
    expect(linear!.input.title).toBe("[Feedback] Bug: The sidebar flickers when I rename a folder.");
    expect(linear!.input.description).toContain("anna\\@example\\.com");
    expect(linear!.input.description).toContain("macOS 15\\.2");
    expect(linear!.input.description).toContain("**Signed in:** no");

    const stored = await row(json.id);
    expect(stored).toMatchObject({ status: "sent", payload: null, linear_issue: "GON-7", kind: "bug" });
  });

  it("works signed out and with a sign-in, sending only a signed-in flag", async () => {
    const dev = await device();
    const res = await send({ message: "Love it", includeDiagnostics: false }, { token: dev.token });
    expect(res.status).toBe(201);
    const description = linearCalls[0]!.input.description;
    expect(description).toContain("**Signed in:** yes");
    expect(description).not.toContain(dev.userId);
    expect(description).toContain("no email given");

    // An invalid token is not an error: it just counts as signed out.
    expect((await send({ message: "Hello", includeDiagnostics: false }, { token: "not.a.token" })).status).toBe(201);
    expect(linearCalls[1]!.input.description).toContain("**Signed in:** no");
  });

  it("defaults to 'other', which has no kind label here, and keeps the feedback label", async () => {
    expect((await send({ message: "Just saying hi", includeDiagnostics: false })).status).toBe(201);
    expect(linearCalls[0]!.input.title).toBe("[Feedback] Other: Just saying hi");
    expect(linearCalls[0]!.input.labelIds).toEqual(["label-feedback"]);
  });

  it("ignores diagnostics unless the user opted in", async () => {
    const res = await send({ message: "No device info please", includeDiagnostics: false, diagnostics });
    expect(res.status).toBe(201);
    const description = linearCalls[0]!.input.description;
    expect(description).not.toContain("Mac14");
    expect(description).toContain("No diagnostics");
  });

  it("validates every field", async () => {
    const bad: unknown[] = [
      { includeDiagnostics: false },
      { message: "", includeDiagnostics: false },
      { message: "   \n ", includeDiagnostics: false },
      { message: "x".repeat(5001), includeDiagnostics: false },
      { message: "ok" },
      { message: "ok", includeDiagnostics: "yes" },
      { message: "ok", includeDiagnostics: false, kind: "rant" },
      { message: "ok", includeDiagnostics: true },
      { message: "ok", includeDiagnostics: true, diagnostics: { ...diagnostics, app: "android" } },
      { message: "ok", includeDiagnostics: true, diagnostics: { ...diagnostics, appVersion: "1".repeat(33) } },
      { message: "ok", includeDiagnostics: true, diagnostics: { ...diagnostics, deviceModel: "<script>" } },
      { message: "ok", includeDiagnostics: true, diagnostics: { ...diagnostics, noteTitle: "Secret" } },
      { message: "ok", includeDiagnostics: false, accountEmail: "a@b.co" },
      [],
    ];
    for (const body of bad) {
      const res = await send(body);
      expect(res.status, JSON.stringify(body)).toBe(400);
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe("invalid_request");
    }
    for (const replyEmail of ["not an email", "a@b", `${"a".repeat(250)}@example.com`, 7]) {
      const res = await send({ message: "ok", includeDiagnostics: false, replyEmail });
      expect(res.status).toBe(400);
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe("invalid_email");
    }
    expect((await send(null, { raw: "{not json" })).status).toBe(400);
    expect((await send(null, { raw: JSON.stringify({ message: "a".repeat(40000), includeDiagnostics: false }) })).status).toBe(413);
    expect(linearCalls).toHaveLength(0);

    // 5000 characters are fine, counted as characters rather than UTF-16 units.
    expect((await send({ message: "é".repeat(2500) + "😀".repeat(2500), includeDiagnostics: false })).status).toBe(201);
  });

  it("rate-limits per network", async () => {
    const ip = freshIp();
    for (let i = 0; i < 5; i++) expect((await send({ message: `n${i}`, includeDiagnostics: false }, { ip })).status).toBe(201);
    const limited = await send({ message: "one more", includeDiagnostics: false }, { ip });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBeTruthy();
    // Another network is unaffected.
    expect((await send({ message: "other network", includeDiagnostics: false })).status).toBe(201);
  });

  it("enforces the global daily cap from the env var", async () => {
    const capped = { ...env, GLOBAL_DAILY_FEEDBACK_CAP: "2" } as Env;
    const day = Date.UTC(2031, 0, 1, 12);
    const input = parseFeedback({ message: "cap", includeDiagnostics: false });
    await submitFeedback(capped, input, { ip: freshIp(), signedIn: false }, day);
    await submitFeedback(capped, input, { ip: freshIp(), signedIn: false }, day);
    await expect(submitFeedback(capped, input, { ip: freshIp(), signedIn: false }, day)).rejects.toMatchObject({ status: 429, code: "rate_limited" });
  });

  it("stores the message when Linear fails and says so", async () => {
    linearResponder = () => new Response("nope", { status: 500 });
    const res = await send({ kind: "idea", message: "Dark mode", includeDiagnostics: false });
    expect(res.status).toBe(502);
    const json = (await res.json()) as { error: { code: string }; id: string; queued: boolean };
    expect(json.error.code).toBe("feedback_delivery_failed");
    expect(json.queued).toBe(true);
    const stored = await row(json.id);
    expect(stored).toMatchObject({ status: "pending", attempts: 1, last_error: "http_500" });
    expect(JSON.parse(stored!.payload as string)).toMatchObject({ message: "Dark mode", kind: "idea", signedIn: false });

    // GraphQL errors count as failures too.
    linearResponder = () => Response.json({ errors: [{ message: "Entity not found" }] });
    const second = await send({ message: "x", includeDiagnostics: false });
    expect(second.status).toBe(502);
    expect(await row(((await second.json()) as { id: string }).id)).toMatchObject({ last_error: "graphql_error" });
  });

  it("stores the message when Linear is not configured", async () => {
    const unconfigured = { ...env, LINEAR_API_KEY: undefined, LINEAR_TEAM_ID: "" } as Env;
    const result = await submitFeedback(unconfigured, parseFeedback({ message: "Hi", includeDiagnostics: false }), { ip: freshIp(), signedIn: false });
    expect(result).toMatchObject({ status: "queued", reason: "not_configured" });
    expect(linearCalls).toHaveLength(0);
    expect(await row(result.id)).toMatchObject({ status: "pending", last_error: "not_configured" });
    // Through HTTP the code is feedback_not_configured (503); covered by queuedError, see PROTOCOL.md.
  });

  it("never stores the IP or an account id", async () => {
    const dev = await device();
    const ip = freshIp();
    const res = await send({ message: "privacy check", includeDiagnostics: false }, { ip, token: dev.token });
    const id = ((await res.json()) as { id: string }).id;
    const dump = JSON.stringify(await row(id));
    expect(dump).not.toContain(ip);
    expect(dump).not.toContain(dev.userId);
  });
});

describe("project and triage state", () => {
  const placed = () => ({ ...env, LINEAR_PROJECT_ID: "project-matilde", LINEAR_STATE_ID: "state-triage" }) as Env;
  const input = () => parseFeedback({ message: "Placement", includeDiagnostics: false });

  it("are skipped when unset", async () => {
    expect((await send({ message: "plain", includeDiagnostics: false })).status).toBe(201);
    expect(linearCalls[0]!.input).not.toHaveProperty("projectId");
    expect(linearCalls[0]!.input).not.toHaveProperty("stateId");
  });

  it("are passed to issueCreate when set", async () => {
    const result = await submitFeedback(placed(), input(), { ip: freshIp(), signedIn: false });
    expect(result.status).toBe("sent");
    expect(linearCalls).toHaveLength(1);
    expect(linearCalls[0]!.input).toMatchObject({ projectId: "project-matilde", stateId: "state-triage" });
  });

  it("are dropped for one retry when Linear rejects them", async () => {
    linearResponder = () => (linearCalls.length === 1 ? Response.json({ errors: [{ message: "Entity not found: Project" }] }) : linearOk("GON-3"));
    const result = await submitFeedback(placed(), input(), { ip: freshIp(), signedIn: false });
    expect(result).toMatchObject({ status: "sent", issue: "GON-3" });
    expect(linearCalls).toHaveLength(2);
    expect(linearCalls[1]!.input).not.toHaveProperty("projectId");
    expect(linearCalls[1]!.input).not.toHaveProperty("stateId");
    expect(linearCalls[1]!.input.labelIds).toEqual(["label-feedback"]);
  });

  it("don't cause a retry on server errors", async () => {
    linearResponder = () => new Response("down", { status: 503 });
    const result = await submitFeedback(placed(), input(), { ip: freshIp(), signedIn: false });
    expect(result).toMatchObject({ status: "queued", reason: "http_503" });
    expect(linearCalls).toHaveLength(1);
  });
});

describe("feedback retry cron", () => {
  it("delivers pending rows, gives up after the attempt limit and drops old sent rows", async () => {
    await env.DB.prepare("DELETE FROM feedback").run();
    const start = Date.UTC(2032, 5, 1);
    linearResponder = () => new Response("down", { status: 503 });
    const queued = await submitFeedback(env, parseFeedback({ message: "retry me", includeDiagnostics: false }), { ip: freshIp(), signedIn: false }, start);
    expect(queued.status).toBe("queued");

    // Too fresh: the cron leaves it alone.
    expect(await retryFeedback(env, start + 1000)).toEqual({ sent: 0, pending: 0 });

    linearResponder = () => linearOk("GON-99");
    const later = start + FEEDBACK_RETRY.minAgeMs + 1000;
    expect(await retryFeedback(env, later)).toEqual({ sent: 1, pending: 0 });
    expect(await row(queued.id)).toMatchObject({ status: "sent", payload: null, linear_issue: "GON-99", attempts: 2 });

    // Old delivered rows are deleted.
    await retryFeedback(env, later + FEEDBACK_RETRY.sentRetentionMs + 1000);
    expect(await row(queued.id)).toBeNull();

    // A row that keeps failing becomes 'failed' and keeps its text for manual handling.
    linearResponder = () => new Response("down", { status: 503 });
    const stuck = await submitFeedback(env, parseFeedback({ message: "stuck", includeDiagnostics: false }), { ip: freshIp(), signedIn: false }, start);
    for (let i = 1; i < FEEDBACK_RETRY.maxAttempts; i++) await retryFeedback(env, later + i);
    const failed = await row(stuck.id);
    expect(failed).toMatchObject({ status: "failed", attempts: FEEDBACK_RETRY.maxAttempts });
    expect(failed!.payload).toContain("stuck");
  });
});

describe("issue formatting", () => {
  it("escapes Markdown so the message can't inject markup", () => {
    const escaped = escapeMarkdown("# Title\n[click](https://evil.example) ![img](x) <b>hi</b> `code` *bold* @filip");
    expect(escaped).not.toMatch(/(^|[^\\])[#\[\]()<>`*@!]/);
    expect(escaped).toContain("  \n");
    expect(escapeMarkdown("    indented")).not.toMatch(/^ {4}/);
  });

  it("puts the message, reply email and diagnostics in the description", () => {
    const payload = { kind: "idea" as const, message: "Split view\n- for drafts", replyEmail: "a_b@example.com", signedIn: true, diagnostics: { app: "ios" as const, appVersion: "1.0", build: "7", osVersion: "iOS 26.1", deviceModel: "iPhone17,1" } };
    const description = issueDescription(payload);
    expect(description).toContain("Split view  \n\\- for drafts");
    expect(description).toContain("a\\_b@example".replace("@", "\\@"));
    expect(description).toContain("- App: iPhone 1\\.0 (build 7)");
    expect(description).toContain("- Device: iPhone17,1");
    expect(issueTitle(payload)).toBe("[Feedback] Idea: Split view - for drafts");
    expect(issueTitle({ ...payload, message: "a".repeat(100) })).toBe(`[Feedback] Idea: ${"a".repeat(60)}…`);
  });
});

describe("cron schedule", () => {
  it("runs directory cleanup only on the 03:15 UTC run of the 15-minute cron", () => {
    const runs = Array.from({ length: 96 }, (_, i) => Date.UTC(2026, 10, 22, 0, i * 15));
    const daily = runs.filter(isDailyRun).map((t) => new Date(t).toISOString());
    expect(daily).toEqual(["2026-11-22T03:15:00.000Z"]);
  });
});
