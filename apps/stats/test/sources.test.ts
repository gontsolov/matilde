import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { escapeHtml, renderPage } from "../src/page";
import { eventsQuery, githubDownloads, lastDays, series, siteVisits, webEvents, windows } from "../src/sources";
import type { SyncStats } from "../src/types";

const NOW = Date.parse("2026-11-22T12:00:00Z");
const env: Env = { GITHUB_REPO: "gontsolov/matilde", EVENTS_DATASET: "matilde_web_events", CF_ACCOUNT_ID: "acc", CF_ANALYTICS_TOKEN: "tok", WEB_ANALYTICS_SITE_TAG: "site" };

function stubFetch(routes: Record<string, (req: Request) => Response>) {
  const calls: Request[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    calls.push(req);
    const route = Object.keys(routes).find((prefix) => req.url.startsWith(prefix));
    return route ? routes[route]!(req) : new Response("not found", { status: 404 });
  }) as typeof fetch;
  return { fetcher, calls };
}

describe("day helpers", () => {
  it("builds 30 UTC days ending today and sums windows", () => {
    const days = lastDays(NOW);
    expect(days).toHaveLength(30);
    expect(days[29]).toBe("2026-11-22");
    expect(days[0]).toBe("2026-10-24");
    const values = series([{ day: "2026-11-22", value: 2 }, { day: "2026-11-22", value: 1 }, { day: "2026-11-16", value: 4 }, { day: "2026-11-15", value: 8 }, { day: "2020-01-01", value: 99 }], days);
    expect(windows(values)).toEqual({ today: 3, week: 7, month: 15 });
  });
});

describe("Analytics Engine", () => {
  it("queries the dataset with the token and maps the rows", async () => {
    const { fetcher, calls } = stubFetch({
      "https://api.cloudflare.com/client/v4/accounts/acc/analytics_engine/sql": () =>
        Response.json({ data: [{ day: "2026-11-22 00:00:00", event: "appcast", version: "0.4.0", os: "15", count: "3" }] }),
    });
    const result = await webEvents(env, fetcher);
    expect(result).toEqual({ ok: true, value: [{ day: "2026-11-22", event: "appcast", version: "0.4.0", os: "15", count: 3 }] });
    expect(calls[0]!.headers.get("Authorization")).toBe("Bearer tok");
    expect(await calls[0]!.text()).toContain("FROM matilde_web_events");
  });

  it("refuses odd dataset names and reports missing secrets", async () => {
    expect(() => eventsQuery("x; DROP")).toThrow();
    expect(await webEvents({ ...env, CF_ANALYTICS_TOKEN: undefined })).toEqual({ ok: false, error: "CF_ACCOUNT_ID or CF_ANALYTICS_TOKEN is not set" });
  });
});

describe("Web Analytics", () => {
  it("is skipped without a site tag and maps visits by day", async () => {
    expect(await siteVisits({ ...env, WEB_ANALYTICS_SITE_TAG: undefined }, NOW)).toBeNull();
    const { fetcher, calls } = stubFetch({
      "https://api.cloudflare.com/client/v4/graphql": () =>
        Response.json({ data: { viewer: { accounts: [{ rumPageloadEventsAdaptiveGroups: [{ count: 12, sum: { visits: 9 }, dimensions: { date: "2026-11-21" } }] }] } }, errors: null }),
    });
    expect(await siteVisits(env, NOW, fetcher)).toEqual({ ok: true, value: [{ day: "2026-11-21", visits: 9, pageViews: 12 }] });
    const body = (await calls[0]!.json()) as { variables: Record<string, string> };
    expect(body.variables).toEqual({ accountTag: "acc", siteTag: "site", since: "2026-10-24", until: "2026-11-22" });
  });

  it("surfaces GraphQL errors", async () => {
    const { fetcher } = stubFetch({ "https://api.cloudflare.com/client/v4/graphql": () => Response.json({ data: null, errors: [{ message: "not authorized" }] }) });
    expect(await siteVisits(env, NOW, fetcher)).toEqual({ ok: false, error: "GraphQL Analytics: not authorized" });
  });
});

describe("GitHub", () => {
  it("reads per-asset download counts and skips drafts", async () => {
    const { fetcher, calls } = stubFetch({
      "https://api.github.com/repos/gontsolov/matilde/releases": () =>
        Response.json([
          { tag_name: "v0.3.1", published_at: "2026-11-21T10:00:00Z", draft: false, assets: [{ name: "Matilde.dmg", download_count: 40 }, { name: "appcast.xml", download_count: 300 }, { name: "SHA256SUMS", download_count: 2 }] },
          { tag_name: "v0.3.2", published_at: null, draft: true, assets: [] },
        ]),
    });
    expect(await githubDownloads(env, fetcher)).toEqual({ ok: true, value: [{ tag: "v0.3.1", publishedAt: "2026-11-21", dmg: 40, appcast: 300 }] });
    expect(calls[0]!.headers.get("User-Agent")).toBe("matilde-stats");
    expect(calls[0]!.headers.get("Authorization")).toBeNull();
  });
});

describe("page", () => {
  it("shows every section with today, 7 and 30 days, and escapes text", () => {
    const sync: SyncStats = {
      generatedAt: new Date(NOW).toISOString(),
      environment: "production",
      current: { accounts: 12, active7d: 5, active30d: 9, devices: { macos: 10, ios: 4 }, recordsLive: 1234, draftsLive: 87 },
      newAccounts: [{ day: "2026-11-22", value: 2 }],
      feedback: [{ day: "2026-11-21", kind: "bug", value: 1 }],
      daily: { active_7d: [{ day: "2026-11-22", value: 5 }] },
    };
    const html = renderPage({
      nowMs: NOW,
      events: {
        ok: true,
        value: [
          { day: "2026-11-22", event: "download", version: "", os: "", count: 4 },
          { day: "2026-11-21", event: "appcast", version: "0.4.0", os: "15", count: 7 },
          { day: "2026-11-21", event: "appcast", version: "0.3.1", os: "unknown", count: 7 },
        ],
      },
      visits: { ok: true, value: [{ day: "2026-11-22", visits: 30, pageViews: 41 }] },
      releases: { ok: true, value: [{ tag: "v0.3.1<b>", publishedAt: "2026-11-21", dmg: 40, appcast: 300 }] },
      sync: { ok: true, value: sync },
    });
    for (const text of ["Visits", "Download clicks", "Update checks per day", "Macs a day", "estimate", "macOS 15", "0.4.0", "Accounts", "Notes and drafts", "1,234", "iPhone 4", "Feedback sent", "bug 1"]) {
      expect(html).toContain(text);
    }
    expect(html).toContain("v0.3.1&lt;b&gt;");
    expect(html).not.toContain("<b>");
    // ≈ 14 checks over the last 7 full days → 2 a day.
    expect(html).toContain("≈ 2");
    expect(html).not.toMatch(/<script/i);
  });

  it("escapes HTML", () => {
    expect(escapeHtml(`<a href="x">'&'</a>`)).toBe("&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  });
});
