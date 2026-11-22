import type { Env } from "../env";
import { utcDay } from "../util";

/** Adds deltas to the running totals in `stats_totals`. Zero deltas are skipped. */
export async function addTotals(db: D1Database, deltas: Record<string, number>): Promise<void> {
  const statements = Object.entries(deltas)
    .filter(([, delta]) => delta !== 0)
    .map(([metric, delta]) =>
      db
        .prepare("INSERT INTO stats_totals (metric, value) VALUES (?, ?) ON CONFLICT(metric) DO UPDATE SET value = value + excluded.value")
        .bind(metric, delta),
    );
  if (statements.length) await db.batch(statements);
}

/** Adds one to a per-day counter (e.g. a feedback submission). */
export async function countDaily(db: D1Database, metric: string, nowMs = Date.now()): Promise<void> {
  await db
    .prepare("INSERT INTO stats_daily (day, metric, value) VALUES (?, ?, 1) ON CONFLICT(day, metric) DO UPDATE SET value = value + 1")
    .bind(utcDay(nowMs), metric)
    .run();
}

export const DAY_MS = 24 * 3600 * 1000;

/** Accounts with a device seen on or after the day `days - 1` days ago (so 7 = today and the 6 days before). */
export function activeSince(nowMs: number, days: number): string {
  return utcDay(nowMs - (days - 1) * DAY_MS);
}

export interface CurrentTotals {
  accounts: number;
  active7d: number;
  active30d: number;
  /** Signed-in devices (sessions) per platform: "macos", "ios", "ipados", … */
  devices: Record<string, number>;
  recordsLive: number;
  draftsLive: number;
}

/**
 * Current totals from the directory. A handful of COUNT queries over small tables;
 * no Durable Object is touched. "Active" means a device of the account refreshed its
 * session that day (sessions.last_seen_day, kept at day resolution on purpose).
 */
export async function currentTotals(env: Env, nowMs = Date.now()): Promise<CurrentTotals> {
  const [accounts, active7, active30, devices, totals] = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare("SELECT COUNT(*) AS n FROM accounts"),
    env.DB.prepare("SELECT COUNT(DISTINCT account_id) AS n FROM sessions WHERE last_seen_day >= ?").bind(activeSince(nowMs, 7)),
    env.DB.prepare("SELECT COUNT(DISTINCT account_id) AS n FROM sessions WHERE last_seen_day >= ?").bind(activeSince(nowMs, 30)),
    env.DB.prepare("SELECT platform, COUNT(*) AS n FROM sessions GROUP BY platform"),
    env.DB.prepare("SELECT metric, value FROM stats_totals"),
  ]);
  const n = (result: D1Result<Record<string, unknown>> | undefined) => Number(result?.results[0]?.n ?? 0);
  const total = (metric: string) => Math.max(0, Number(totals?.results.find((row) => row.metric === metric)?.value ?? 0));
  return {
    accounts: n(accounts),
    active7d: n(active7),
    active30d: n(active30),
    devices: Object.fromEntries((devices?.results ?? []).map((row) => [String(row.platform), Number(row.n)])),
    recordsLive: total("records_live"),
    draftsLive: total("drafts_live"),
  };
}

/** Cron (every run): today's snapshot of the totals, overwritten until the day ends. */
export async function snapshotStats(env: Env, nowMs = Date.now()): Promise<void> {
  const totals = await currentTotals(env, nowMs);
  const day = utcDay(nowMs);
  const metrics: Record<string, number> = {
    accounts: totals.accounts,
    active_7d: totals.active7d,
    active_30d: totals.active30d,
    records_live: totals.recordsLive,
    drafts_live: totals.draftsLive,
  };
  for (const [platform, count] of Object.entries(totals.devices)) metrics[`devices:${platform}`] = count;
  await env.DB.batch(
    Object.entries(metrics).map(([metric, value]) =>
      env.DB.prepare("INSERT INTO stats_daily (day, metric, value) VALUES (?, ?, ?) ON CONFLICT(day, metric) DO UPDATE SET value = excluded.value").bind(
        day,
        metric,
        value,
      ),
    ),
  );
}
