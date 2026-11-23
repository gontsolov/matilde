// MCP server for AI tools (docs/mcp.md): crypto against docs/sync-vectors, the consent page's
// browser module, the full OAuth flow, tools, scopes, limits, audit, revocation and expiry.

import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import vectors from "../../docs/sync-vectors/v1.json";
import { memoryOutbox } from "../src/auth/mailer";
import { decodePlaintext, decodeRing, encodeRing, keyCheck, type KeyRing, openRecord, paddedLength, pad, unframe, unpad, unwrapRing, unwrapSlot, wrapRing, sealRecord, openField } from "../src/mcp/crypto";
import { d1Kv } from "../src/mcp/kv";
import { BIP39_WORDS } from "../src/mcp/web/assets.generated";
import * as connect from "../src/mcp/web/connect.js";
import { authed, device, pullAll } from "./helpers";

const MCP = "https://mcp.test";
const REDIRECT = "https://client.example/callback";
const WORDS = BIP39_WORDS.trim().split("\n");
const RECOVERY_CODE = vectors.recoveryCodes[0]!.code;
const USER_ID = vectors.userId;

const bytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
const b64url = (u: Uint8Array) => b64(u).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fetchWorker = (req: Request) => (exports as unknown as { default: Fetcher }).default.fetch(req);
const ring: KeyRing = { userId: USER_ID, keys: [...vectors.accountKeys].reverse().map((k) => ({ id: k.keyId, key: bytes(k.key) })) };

let ipCounter = 0;
const freshIp = () => `198.51.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`;

// MARK: crypto vectors

describe("MCP crypto matches docs/sync-vectors", () => {
  it("seals records to the exact vector envelopes and opens them", async () => {
    for (const r of vectors.records) {
      const keys = { userId: USER_ID, keys: [{ id: r.keyId, key: bytes(vectors.accountKeys.find((k) => k.keyId === r.keyId)!.key) }] };
      const context = { userId: USER_ID, recordId: r.recordId, type: r.type, hlc: r.hlc, deleted: r.deleted };
      const sealed = await sealRecord(keys, context, bytes(r.plaintext), bytes(r.salt), bytes(r.nonce));
      expect(b64(sealed)).toBe(r.envelope);
      expect(b64(await openRecord(ring, context, bytes(r.envelope), r.keyId))).toBe(r.plaintext);
      await expect(openRecord(ring, { ...context, hlc: `${r.hlc.slice(0, 12)}9${r.hlc.slice(13)}` }, bytes(r.envelope))).rejects.toThrow();
    }
  });

  it("opens field envelopes, key slots and checks key checks", async () => {
    for (const f of vectors.fields) {
      expect(b64(await openField(ring, f.purpose, f.subject, bytes(f.envelope)))).toBe(f.plaintext);
    }
    for (const s of vectors.slots) {
      const opened = await unwrapSlot(bytes(s.secret), bytes(s.wrappedKey), { userId: USER_ID, slotId: s.slotId, kind: s.kind, keyId: s.keyId });
      expect(b64(opened)).toBe(s.plaintext);
    }
    for (const k of vectors.accountKeys) expect(b64(await keyCheck(bytes(k.key), k.keyId))).toBe(k.keyCheck);
  });

  it("pads like Padmé", () => {
    for (const p of vectors.padding) {
      expect(paddedLength(p.length)).toBe(p.padded);
      if (p.length <= 65535) {
        const plain = new Uint8Array(p.length).fill(7);
        const padded = pad(plain);
        expect(padded.length).toBe(p.padded);
        expect(unpad(padded)).toEqual(plain);
      }
    }
  });

  it("wraps the ring for a grant and binds it to the user and grant", async () => {
    const secret = crypto.getRandomValues(new Uint8Array(32));
    const grantId = crypto.randomUUID();
    const wrapped = await wrapRing(secret, USER_ID, grantId, ring.keys);
    expect((await unwrapRing(secret, USER_ID, grantId, wrapped)).keys).toEqual(ring.keys);
    await expect(unwrapRing(secret, USER_ID, crypto.randomUUID(), wrapped)).rejects.toThrow();
    await expect(unwrapRing(secret, crypto.randomUUID(), grantId, wrapped)).rejects.toThrow();
    expect(decodeRing(encodeRing(ring.keys))).toEqual(ring.keys);
  });
});

describe("consent page module (connect.js)", () => {
  it("derives Matilde key secrets and reads recovery codes like the apps", async () => {
    for (const m of vectors.matildeKeys) {
      expect(b64(await connect.wordsEntropy(m.words, WORDS))).toBe(m.entropy);
      expect(b64(await connect.slotSecret(m.words, WORDS))).toBe(m.secret);
      // Numbering and 4-letter prefixes are accepted, like the apps.
      const numbered = m.words.split(" ").map((w, i) => `${i + 1}. ${w.length > 4 ? w.slice(0, 4) : w}`).join("\n");
      expect(b64(await connect.slotSecret(numbered, WORDS))).toBe(m.secret);
    }
    for (const r of vectors.recoveryCodes) expect(b64(await connect.slotSecret(r.code, WORDS))).toBe(r.key);
    const typo = vectors.matildeKeys[0]!.words.replace(/^hawk/, "hello");
    await expect(connect.slotSecret(typo, WORDS)).rejects.toMatchObject({ code: expect.stringMatching(/typo|invalid/) });
  });

  it("unlocks the ring from the slots and wraps it so the server can open it", async () => {
    const keys = {
      userId: USER_ID,
      keyId: 2,
      keyCheck: vectors.accountKeys.find((k) => k.keyId === 2)!.keyCheck,
      slots: vectors.slots.map((s) => ({ slotId: s.slotId, kind: s.kind, keyId: s.keyId, params: null, wrappedKey: s.wrappedKey })),
    };
    const unlocked = await connect.unlockRing(keys, RECOVERY_CODE, WORDS);
    expect(unlocked.map((k) => k.id)).toEqual([2, 1]);
    expect(unlocked).toEqual(ring.keys);
    await expect(connect.unlockRing(keys, vectors.recoveryCodes[1]!.code, WORDS)).rejects.toMatchObject({ code: "wrong" });
    const wrap = await connect.wrapForGrant(USER_ID, unlocked);
    const opened = await unwrapRing(bytes(wrap.grantSecret), USER_ID, wrap.grantId, bytes(wrap.wrappedRing));
    expect(opened.keys).toEqual(ring.keys);
  });
});

describe("D1 KV adapter", () => {
  it("gets, puts with expiry and metadata, lists by prefix and deletes", async () => {
    let now = 1_000_000;
    const kv = d1Kv(env.DB, () => now);
    await kv.put("t:a", JSON.stringify({ x: 1 }), { metadata: { m: 1 } });
    await kv.put("t:b", "two", { expirationTtl: 60 });
    await kv.put("u:c", "three");
    expect(await kv.get("t:a", { type: "json" })).toEqual({ x: 1 });
    expect(await kv.get("t:b")).toBe("two");
    const listed = await kv.list({ prefix: "t:" });
    expect(listed.keys.map((k) => k.name)).toEqual(["t:a", "t:b"]);
    now += 61_000;
    expect(await kv.get("t:b")).toBeNull();
    await kv.delete("t:a");
    expect(await kv.get("t:a")).toBeNull();
  });
});

// MARK: full flow

async function seedAccount(email: string) {
  const k2 = vectors.accountKeys.find((k) => k.keyId === 2)!;
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO accounts (id, created_at, key_id, key_check) VALUES (?, ?, 2, ?)").bind(USER_ID, Date.now(), k2.keyCheck),
    env.DB.prepare("INSERT OR IGNORE INTO identities (provider, subject, account_id, email, created_at) VALUES ('email', ?, ?, ?, ?)").bind(email, USER_ID, email, Date.now()),
    ...vectors.slots.map((s) =>
      env.DB.prepare("INSERT OR IGNORE INTO key_slots (account_id, slot_id, kind, key_id, params, wrapped_key, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?)").bind(
        USER_ID,
        s.slotId,
        s.kind,
        s.keyId,
        s.wrappedKey,
        Date.now(),
      ),
    ),
  ]);
}

function lastCode(to: string): string {
  const mail = [...memoryOutbox()].reverse().find((m) => m.to === to);
  if (!mail) throw new Error(`no mail to ${to}`);
  return /\b(\d{6})\b/.exec(mail.text)![1]!;
}

async function register(name = "Test Tool"): Promise<string> {
  const res = await fetchWorker(
    new Request(`${MCP}/oauth/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ redirect_uris: [REDIRECT], client_name: name, token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] }),
    }),
  );
  expect(res.status).toBe(201);
  return ((await res.json()) as { client_id: string }).client_id;
}

interface Connected {
  clientId: string;
  accessToken: string;
  refreshToken: string;
  grantId: string;
}

async function connectTool(opts: { scopes: string[]; days?: number; email?: string; name?: string; key?: string; forgeRing?: boolean; expectApprove?: number }): Promise<Connected> {
  const email = opts.email ?? `writer-${crypto.randomUUID().slice(0, 8)}@example.com`;
  const ip = freshIp();
  const clientId = await register(opts.name);
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const challenge = b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  const q = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: REDIRECT,
    scope: opts.scopes.join(" "),
    state: "st4te",
    code_challenge: challenge,
    code_challenge_method: "S256",
    resource: `${MCP}/mcp`,
  });
  const page = await fetchWorker(new Request(`${MCP}/authorize?${q}`));
  expect(page.status).toBe(200);
  expect(page.headers.get("Content-Security-Policy")).toContain("frame-ancestors 'none'");
  const html = await page.text();
  const handle = /data-handle="([^"]+)"/.exec(html)![1]!.replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)));
  const cookie = page.headers
    .getSetCookie()
    .map((c) => c.split(";")[0])
    .join("; ");
  const post = (path: string, body: unknown, extra: Record<string, string> = {}) =>
    fetchWorker(
      new Request(`${MCP}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Matilde-Connect": "1", "CF-Connecting-IP": ip, Cookie: cookie, ...extra },
        body: JSON.stringify(body),
      }),
    );

  const wantsNotes = opts.scopes.some((s) => s !== "feedback");
  let body: Record<string, unknown> = { handle, scopes: opts.scopes, days: opts.days ?? 30 };
  let login: string | undefined;
  if (wantsNotes) {
    await seedAccount(email);
    expect((await post("/connect/code", { handle, email })).status).toBe(200);
    const verified = await post("/connect/verify", { handle, email, code: lastCode(email) });
    expect(verified.status).toBe(200);
    const keys = (await verified.json()) as connect.ConnectKeys & { login: string };
    login = keys.login;
    const unlocked = opts.forgeRing
      ? [{ id: 2, key: crypto.getRandomValues(new Uint8Array(32)) }]
      : await connect.unlockRing(keys, opts.key ?? RECOVERY_CODE, WORDS);
    body = { ...body, ...(await connect.wrapForGrant(keys.userId, unlocked)) };
  }
  const approved = await post("/connect/approve", body, login ? { "X-Matilde-Login": login } : {});
  expect(approved.status).toBe(opts.expectApprove ?? 200);
  if (opts.expectApprove) throw new Error(((await approved.json()) as { error: { code: string } }).error.code);
  const { redirectTo } = (await approved.json()) as { redirectTo: string };
  const back = new URL(redirectTo);
  expect(back.origin + back.pathname).toBe(REDIRECT);
  expect(back.searchParams.get("state")).toBe("st4te");
  const code = back.searchParams.get("code")!;

  const tokenRes = await fetchWorker(
    new Request(`${MCP}/oauth/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: REDIRECT, client_id: clientId, code_verifier: verifier, resource: `${MCP}/mcp` }),
    }),
  );
  expect(tokenRes.status).toBe(200);
  const tokens = (await tokenRes.json()) as { access_token: string; refresh_token: string };
  const grantId = (body.grantId as string | undefined) ?? (await env.DB.prepare("SELECT id FROM mcp_grants WHERE client_id = ?").bind(clientId).first<{ id: string }>())!.id;
  return { clientId, accessToken: tokens.access_token, refreshToken: tokens.refresh_token, grantId };
}

let rpcId = 0;
async function rpc(c: Connected, method: string, params: Record<string, unknown> = {}): Promise<Response> {
  return fetchWorker(
    new Request(`${MCP}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", Authorization: `Bearer ${c.accessToken}` },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
    }),
  );
}

async function tool(c: Connected, name: string, args: Record<string, unknown> = {}) {
  const res = await rpc(c, "tools/call", { name, arguments: args });
  expect(res.status).toBe(200);
  const body = (await res.json()) as { result: { isError: boolean; structuredContent: Record<string, any> } };
  return body.result;
}

const realFetch = globalThis.fetch;
beforeEach(() => {
  memoryOutbox().length = 0;
  // leave_feedback goes to Linear; answer like Linear does.
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.startsWith("https://api.linear.app/")) {
      return Response.json({ data: { issueCreate: { success: true, issue: { id: "issue-1", identifier: "GON-1" } } } });
    }
    return realFetch(input, init);
  });
});
afterEach(() => vi.restoreAllMocks());

describe("MCP over OAuth", () => {
  beforeAll(() => undefined);

  it("publishes OAuth metadata and challenges unauthenticated calls", async () => {
    const meta = await fetchWorker(new Request(`${MCP}/.well-known/oauth-authorization-server`));
    expect(meta.status).toBe(200);
    const json = (await meta.json()) as { scopes_supported: string[]; authorization_endpoint: string };
    expect(json.scopes_supported).toContain("notes:edit");
    expect(json.authorization_endpoint).toBe(`${MCP}/authorize`);
    const resource = await fetchWorker(new Request(`${MCP}/.well-known/oauth-protected-resource/mcp`));
    expect(resource.status).toBe(200);
    const res = await fetchWorker(new Request(`${MCP}/mcp`, { method: "POST", body: "{}" }));
    expect(res.status).toBe(401);
    expect(res.headers.get("WWW-Authenticate")).toContain("resource_metadata");
  });

  it("shows the consent page with notes:edit off by default and escapes the client name", async () => {
    const clientId = await register('<script>alert(1)</script> "Tool"');
    const q = new URLSearchParams({ response_type: "code", client_id: clientId, redirect_uri: REDIRECT, scope: "notes:read notes:edit", state: "s", code_challenge: "x".repeat(43), code_challenge_method: "S256" });
    const html = await (await fetchWorker(new Request(`${MCP}/authorize?${q}`))).text();
    expect(html).not.toContain("<script>alert");
    expect(html).toContain('value="notes:edit">');
    expect(html).toContain('value="notes:read" checked>');
    expect(html).toContain("client.example");
    expect(html).not.toContain("isn't verified");
  });

  it("serves the consent page's own icon, font, style and script under a strict CSP", async () => {
    const clientId = await register("Tool");
    const q = new URLSearchParams({ response_type: "code", client_id: clientId, redirect_uri: REDIRECT, scope: "notes:read", state: "s", code_challenge: "x".repeat(43), code_challenge_method: "S256" });
    const page = await fetchWorker(new Request(`${MCP}/authorize?${q}`));
    const csp = page.headers.get("Content-Security-Policy")!;
    for (const directive of ["default-src 'none'", "script-src 'self'", "style-src 'self'", "font-src 'self'", "frame-ancestors 'none'"]) expect(csp).toContain(directive);
    const html = await page.text();
    expect(html).not.toMatch(/<script>|style="/);
    expect(html).toContain('name="days" value="30" checked');
    expect(html).toContain('autocomplete="one-time-code"');
    const assets: [string, string, number[]][] = [
      ["/connect/icon.png", "image/png", [0x89, 0x50, 0x4e, 0x47]],
      ["/connect/newsreader.woff2", "font/woff2", [0x77, 0x4f, 0x46, 0x32]],
    ];
    for (const [path, type, magic] of assets) {
      const res = await fetchWorker(new Request(`${MCP}${path}`));
      expect(res.status).toBe(200);
      expect(res.headers.get("Content-Type")).toBe(type);
      expect([...new Uint8Array(await res.arrayBuffer()).slice(0, 4)]).toEqual(magic);
    }
    for (const path of ["/connect/app.css", "/connect/app.js"]) expect((await fetchWorker(new Request(`${MCP}${path}`))).status).toBe(200);
  });

  it("connects, creates, lists, searches, reads and comments; records decrypt for the apps", async () => {
    const c = await connectTool({ scopes: ["notes:read", "notes:comment", "notes:create", "feedback"] });
    const init = (await (await rpc(c, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } })).json()) as { result: { protocolVersion: string } };
    expect(init.result.protocolVersion).toBe("2025-06-18");
    const list = (await (await rpc(c, "tools/list")).json()) as { result: { tools: { name: string }[] } };
    expect(list.result.tools.map((t) => t.name).sort()).toEqual(["add_comment", "create_note", "leave_feedback", "list_notes", "read_note", "search_notes"]);

    const created = await tool(c, "create_note", { title: "Letter to Anna", text: "# Letter\n\nDear Anna, thank you for the lovely café visit." });
    expect(created.isError).toBe(false);
    const id = created.structuredContent.id as string;
    const again = await tool(c, "create_note", { title: "Letter to Anna", text: "Second" });
    expect(again.structuredContent.title).toBe("Letter to Anna 2");

    const listed = await tool(c, "list_notes");
    expect(listed.structuredContent.notes.map((n: { title: string }) => n.title)).toEqual(expect.arrayContaining(["Letter to Anna", "Letter to Anna 2"]));
    const found = await tool(c, "search_notes", { query: "CAFE" });
    expect(found.structuredContent.results.map((r: { id: string }) => r.id)).toContain(id);

    const comment = await tool(c, "add_comment", { id, quote: "lovely café visit", comment: "Maybe name the café?" });
    expect(comment.isError).toBe(false);
    const repeated = await tool(c, "add_comment", { id, quote: "lovely café visit", comment: "  maybe name the café? " });
    expect(repeated.isError).toBe(false);
    expect(repeated.structuredContent).toEqual(expect.objectContaining({ commentId: comment.structuredContent.commentId, alreadyThere: true }));
    const ambiguous = await tool(c, "add_comment", { id, quote: "a", comment: "x" });
    expect(ambiguous.isError).toBe(true);

    const read = await tool(c, "read_note", { id });
    expect(read.structuredContent.text).toContain("Dear Anna");
    expect(read.structuredContent.comments).toEqual([expect.objectContaining({ quote: "lovely café visit", comment: "Maybe name the café?", author: "Test Tool" })]);

    // What the tool wrote is ordinary sync data: the apps' key ring opens and parses it.
    const dev = await device(USER_ID);
    const rows = await pullAll(dev);
    expect(rows.length).toBeGreaterThanOrEqual(5);
    for (const row of rows) {
      const plain = await openRecord(ring, { userId: USER_ID, recordId: row.id, type: row.type, hlc: row.hlc, deleted: row.deleted }, bytes(row.ct!), row.keyId);
      const framed = await unframe(plain);
      expect(framed.kind).toBe("json");
      if (framed.kind === "json") expect(decodePlaintext(framed.json).v).toBe(1);
      expect(row.keyId).toBe(2);
    }

    // Edits need notes:edit, which this connection doesn't have.
    const edit = await tool(c, "edit_note", { id, edits: [{ old_text: "Dear", new_text: "Hi" }] });
    expect(edit.isError).toBe(true);
    expect(edit.structuredContent.error).toBe("not_allowed");

    const feedback = await tool(c, "leave_feedback", { message: "Love it", kind: "idea" });
    expect(feedback.isError).toBe(false);

    // The audit log has tool names and outcomes, never content.
    const audit = await env.DB.prepare("SELECT * FROM mcp_audit WHERE grant_id = ?").bind(c.grantId).all();
    const dump = JSON.stringify(audit.results);
    expect(audit.results.length).toBeGreaterThanOrEqual(9);
    for (const secret of ["Anna", "café", "Love it", "lovely"]) expect(dump).not.toContain(secret);
    const grant = await env.DB.prepare("SELECT * FROM mcp_grants WHERE id = ?").bind(c.grantId).first<Record<string, unknown>>();
    expect(grant!.user_id).toBe(USER_ID);
    expect(grant!.last_used_day).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it("edits with notes:edit using exact replacements", async () => {
    const c = await connectTool({ scopes: ["notes:read", "notes:create", "notes:edit"] });
    const id = (await tool(c, "create_note", { title: `Edit ${crypto.randomUUID().slice(0, 4)}`, text: "One two three." })).structuredContent.id;
    const edited = await tool(c, "edit_note", { id, edits: [{ old_text: "two", new_text: "2" }] });
    expect(edited.structuredContent).toMatchObject({ ok: true, changed: true });
    expect((await tool(c, "read_note", { id })).structuredContent.text).toBe("One 2 three.");
    const missing = await tool(c, "edit_note", { id, edits: [{ old_text: "four", new_text: "4" }] });
    expect(missing.isError).toBe(true);
  });

  it("feedback-only connections need no account and can't see notes", async () => {
    const c = await connectTool({ scopes: ["feedback"] });
    const list = (await (await rpc(c, "tools/list")).json()) as { result: { tools: { name: string }[] } };
    expect(list.result.tools.map((t) => t.name)).toEqual(["leave_feedback"]);
    const row = await env.DB.prepare("SELECT wrapped_ring, user_id FROM mcp_grants WHERE id = ?").bind(c.grantId).first<{ wrapped_ring: unknown; user_id: string }>();
    expect(row!.wrapped_ring).toBeNull();
    expect(row!.user_id).not.toBe(USER_ID);
    expect((await tool(c, "list_notes")).structuredContent.error).toBe("not_allowed");
    expect((await tool(c, "leave_feedback", { message: "Bug: crash" })).isError).toBe(false);
  });

  it("refuses a wrong key in the browser and a ring that isn't the account's on the server", async () => {
    await expect(connectTool({ scopes: ["notes:read"], key: vectors.recoveryCodes[1]!.code })).rejects.toMatchObject({ code: "wrong" });
    await expect(connectTool({ scopes: ["notes:read"], forgeRing: true, expectApprove: 400 })).rejects.toThrow("wrong_key");
  });

  it("rate limits each connection", async () => {
    const c = await connectTool({ scopes: ["notes:read"] });
    const batch = Array.from({ length: 61 }, (_, i) => ({ jsonrpc: "2.0", id: i, method: "tools/call", params: { name: "list_notes", arguments: {} } }));
    const res = await fetchWorker(
      new Request(`${MCP}/mcp`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${c.accessToken}` }, body: JSON.stringify(batch) }),
    );
    const results = (await res.json()) as { result: { isError: boolean; structuredContent: { error?: string } } }[];
    expect(results.filter((r) => r.result.structuredContent.error === "rate_limited").length).toBe(1);
  });

  it("lists connections in the apps and revokes them at once, tokens included", async () => {
    const c = await connectTool({ scopes: ["notes:read"], name: "Revoke Me" });
    const dev = await device(USER_ID);
    const listed = (await (await fetchWorker(new Request("https://sync.test/v1/connections", authed(dev)))).json()) as { connections: { id: string; clientName: string; scopes: string[] }[] };
    expect(listed.connections).toEqual(expect.arrayContaining([expect.objectContaining({ id: c.grantId, clientName: "Revoke Me", scopes: ["notes:read"] })]));
    expect((await tool(c, "list_notes")).isError).toBe(false);
    const activity = (await (await fetchWorker(new Request(`https://sync.test/v1/connections/${c.grantId}/activity`, authed(dev)))).json()) as { activity: { tool: string }[] };
    expect(activity.activity[0]).toMatchObject({ tool: "list_notes", outcome: "ok" });

    // Someone else can't revoke it.
    const other = await device();
    expect((await fetchWorker(new Request(`https://sync.test/v1/connections/${c.grantId}`, authed(other, { method: "DELETE" })))).status).toBe(404);

    expect((await fetchWorker(new Request(`https://sync.test/v1/connections/${c.grantId}`, authed(dev, { method: "DELETE" })))).status).toBe(204);
    expect((await rpc(c, "tools/list")).status).toBe(401);
    const row = await env.DB.prepare("SELECT wrapped_ring, revoked_at FROM mcp_grants WHERE id = ?").bind(c.grantId).first<{ wrapped_ring: unknown; revoked_at: number }>();
    expect(row!.wrapped_ring).toBeNull();
    expect(row!.revoked_at).toBeGreaterThan(0);
    const refresh = await fetchWorker(
      new Request(`${MCP}/oauth/token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: c.refreshToken, client_id: c.clientId }),
      }),
    );
    expect(refresh.status).toBe(400);
    const after = (await (await fetchWorker(new Request("https://sync.test/v1/connections", authed(dev)))).json()) as { connections: { id: string }[] };
    expect(after.connections.map((x) => x.id)).not.toContain(c.grantId);
  });

  it("stops expired connections", async () => {
    const c = await connectTool({ scopes: ["notes:read"], days: 1 });
    expect((await rpc(c, "ping")).status).toBe(200);
    await env.DB.prepare("UPDATE mcp_grants SET expires_at = ? WHERE id = ?").bind(Date.now() - 1, c.grantId).run();
    expect((await rpc(c, "ping")).status).toBe(401);
  });

  it("deny sends the browser back with access_denied", async () => {
    const clientId = await register();
    const q = new URLSearchParams({ response_type: "code", client_id: clientId, redirect_uri: REDIRECT, scope: "notes:read", state: "s1", code_challenge: "y".repeat(43), code_challenge_method: "S256" });
    const page = await fetchWorker(new Request(`${MCP}/authorize?${q}`));
    const handle = /data-handle="([^"]+)"/.exec(await page.text())![1]!;
    const cookie = page.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
    const res = await fetchWorker(
      new Request(`${MCP}/connect/deny`, { method: "POST", headers: { "Content-Type": "application/json", "X-Matilde-Connect": "1", Cookie: cookie }, body: JSON.stringify({ handle }) }),
    );
    const { redirectTo } = (await res.json()) as { redirectTo: string };
    expect(new URL(redirectTo).searchParams.get("error")).toBe("access_denied");
    // Without the custom header (a plain cross-site form post) the endpoints refuse.
    const bare = await fetchWorker(new Request(`${MCP}/connect/deny`, { method: "POST", headers: { "Content-Type": "application/json", Cookie: cookie }, body: JSON.stringify({ handle }) }));
    expect(bare.status).toBe(403);
  });

  it("the sync host doesn't serve MCP and the MCP host doesn't serve sync", async () => {
    expect((await fetchWorker(new Request("https://sync.test/mcp", { method: "POST" }))).status).toBe(404);
    expect((await fetchWorker(new Request(`${MCP}/v1/health`))).status).toBe(404);
  });
});
