import { env, runInDurableObject } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { collectStats, type SyncStats } from "../src/stats/api";
import { activeSince, countDaily, snapshotStats } from "../src/stats/counters";
import { userSync } from "../src/sync/stub";
import { utcDay } from "../src/util";
import { call, change, device, hlc, pull, push, T } from "./helpers";

async function totals(): Promise<{ records: number; drafts: number }> {
  const rows = await env.DB.prepare("SELECT metric, value FROM stats_totals").all<{ metric: string; value: number }>();
  const value = (metric: string) => rows.results.find((r) => r.metric === metric)?.value ?? 0;
  return { records: value("records_live"), drafts: value("drafts_live") };
}

describe("record counters", () => {
  it("adds and removes live records and drafts as a delta, without any account id", async () => {
    const before = await totals();
    const dev = await device();
    const draft = crypto.randomUUID();
    const body = crypto.randomUUID();
    await push(dev, [change({ id: draft, type: T.draft, hlc: hlc(dev) }), change({ id: body, type: T.body, hlc: hlc(dev), baseHlc: null })]);
    expect(await totals()).toEqual({ records: before.records + 2, drafts: before.drafts + 1 });

    // An edit of a live record changes nothing; an idempotent retry neither.
    const edit = change({ id: draft, type: T.draft, hlc: hlc(dev) });
    await push(dev, [edit]);
    await push(dev, [edit]);
    expect(await totals()).toEqual({ records: before.records + 2, drafts: before.drafts + 1 });

    // A tombstone removes it from the totals.
    await push(dev, [change({ id: draft, type: T.draft, hlc: hlc(dev), deleted: true })]);
    expect(await totals()).toEqual({ records: before.records + 1, drafts: before.drafts });

    const counts = await userSync(env, dev.userId).statsCounts();
    expect(counts).toEqual({ liveRecords: 1, liveDrafts: 0, reportedRecords: 1, reportedDrafts: 0 });

    // stats_totals holds only metric names and numbers.
    const columns = await env.DB.prepare("SELECT name FROM pragma_table_info('stats_totals')").all<{ name: string }>();
    expect(columns.results.map((c) => c.name)).toEqual(["metric", "value"]);
  });

  it("retries a report that D1 didn't take on the next pull", async () => {
    const dev = await device();
    await push(dev, [change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev) })]);
    const before = await totals();
    // Simulate a lost report: D1 is one record behind what the object has.
    await env.DB.prepare("UPDATE stats_totals SET value = value - 1 WHERE metric IN ('records_live', 'drafts_live')").run();
    const stub = userSync(env, dev.userId);
    // Pretend the object never reported the record: reported_* back to 0.
    await runInDurableObject(stub, async (_instance, state) => {
      state.storage.sql.exec("UPDATE meta SET value = 0 WHERE key IN ('reported_records', 'reported_drafts')");
    });
    await pull(dev);
    expect(await totals()).toEqual(before);
  });

  it("takes a deleted account's records back out of the totals", async () => {
    const before = await totals();
    const dev = await device();
    await push(dev, [
      change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev) }),
      change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev) }),
      change({ id: crypto.randomUUID(), type: T.comment, hlc: hlc(dev) }),
    ]);
    expect(await totals()).toEqual({ records: before.records + 3, drafts: before.drafts + 2 });
    await userSync(env, dev.userId).deleteAccount(dev.userId);
    expect(await totals()).toEqual(before);
  });
});

describe("directory stats", () => {
  it("counts accounts, active accounts by session day and devices by platform", async () => {
    const now = Date.parse("2026-11-22T12:00:00Z");
    const day = (offset: number) => utcDay(now - offset * 24 * 3600 * 1000);
    const before = await collectStats(env, now);
    const account = async (platforms: [string, number][]) => {
      const id = crypto.randomUUID();
      await env.DB.prepare("INSERT INTO accounts (id, created_at) VALUES (?, ?)").bind(id, now).run();
      for (const [platform, seenDaysAgo] of platforms) {
        await env.DB.prepare(
          `INSERT INTO sessions (id, account_id, device_id, platform, refresh_hash, rotated_at, created_at, last_seen_day, expires_at)
           VALUES (?, ?, ?, ?, 'x', 0, 0, ?, ?)`,
        )
          .bind(crypto.randomUUID(), id, crypto.randomUUID(), platform, day(seenDaysAgo), now + 1e9)
          .run();
      }
    };
    await account([["macos", 0], ["ios", 3]]); // active this week
    await account([["macos", 6]]); // edge of the 7-day window
    await account([["macos", 7]]); // only in the 30-day window
    await account([["ios", 40]]); // inactive

    expect(activeSince(now, 7)).toBe(day(6));
    const after = await collectStats(env, now);
    expect(after.current.accounts - before.current.accounts).toBe(4);
    expect(after.current.active7d - before.current.active7d).toBe(2);
    expect(after.current.active30d - before.current.active30d).toBe(3);
    expect((after.current.devices.macos ?? 0) - (before.current.devices.macos ?? 0)).toBe(3);
    expect((after.current.devices.ios ?? 0) - (before.current.devices.ios ?? 0)).toBe(2);
    const newToday = (s: SyncStats) => s.newAccounts.find((d) => d.day === day(0))?.value ?? 0;
    expect(newToday(after) - newToday(before)).toBe(4);

    // The cron's snapshot keeps today's values; a later run overwrites them.
    await snapshotStats(env, now);
    await snapshotStats(env, now);
    const snapshot = await collectStats(env, now);
    expect(snapshot.daily.accounts?.find((d) => d.day === day(0))?.value).toBe(after.current.accounts);
    expect(snapshot.daily.active_7d?.filter((d) => d.day === day(0))).toHaveLength(1);
  });

  it("counts feedback per day and kind", async () => {
    const now = Date.parse("2026-10-01T08:00:00Z");
    await countDaily(env.DB, "feedback:bug", now);
    await countDaily(env.DB, "feedback:bug", now);
    await countDaily(env.DB, "feedback:idea", now);
    const stats = await collectStats(env, now);
    expect(stats.feedback.filter((f) => f.day === "2026-10-01")).toEqual([
      { day: "2026-10-01", kind: "bug", value: 2 },
      { day: "2026-10-01", kind: "idea", value: 1 },
    ]);
  });
});

describe("admin access", () => {
  it("has no HTTP route: stats are only reachable through the StatsApi service binding", async () => {
    for (const path of ["/v1/stats", "/v1/admin/stats", "/stats", "/admin/stats", "/v1/admin"]) {
      const res = await call(path, { headers: { "Cf-Access-Jwt-Assertion": "x", Authorization: "Bearer x" } });
      expect(res.status).toBe(404);
    }
  });

  it("answers aggregate stats over RPC", async () => {
    const api = (exports as unknown as { StatsApi: { stats(): Promise<SyncStats> } }).StatsApi;
    const stats = await api.stats();
    expect(stats.environment).toBe("test");
    expect(typeof stats.current.accounts).toBe("number");
    // Aggregates only: nothing in the response looks like an id or an address.
    const text = JSON.stringify(stats);
    expect(text).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/);
    expect(text).not.toContain("@");
  });
});
