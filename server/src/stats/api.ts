import { WorkerEntrypoint } from "cloudflare:workers";
import type { Env } from "../env";
import { utcDay } from "../util";
import { type CurrentTotals, currentTotals, DAY_MS } from "./counters";

/** Days of history returned. */
export const STATS_HISTORY_DAYS = 90;

export interface DayValue {
  day: string;
  value: number;
}

/** Everything the stats page shows about sync. Aggregate counts only. */
export interface SyncStats {
  generatedAt: string;
  environment: string;
  current: CurrentTotals;
  /** Accounts created per day (deleted accounts drop out). */
  newAccounts: DayValue[];
  /** Feedback submissions per day and kind ("bug", "idea", "other"). */
  feedback: { day: string; kind: string; value: number }[];
  /** Daily snapshots written by the cron: metric → values per day. */
  daily: Record<string, DayValue[]>;
}

export async function collectStats(env: Env, nowMs = Date.now()): Promise<SyncStats> {
  const since = utcDay(nowMs - (STATS_HISTORY_DAYS - 1) * DAY_MS);
  const sinceMs = Date.parse(`${since}T00:00:00Z`);
  const [current, created, daily] = await Promise.all([
    currentTotals(env, nowMs),
    env.DB.prepare(
      "SELECT strftime('%Y-%m-%d', created_at / 1000, 'unixepoch') AS day, COUNT(*) AS n FROM accounts WHERE created_at >= ? GROUP BY day ORDER BY day",
    )
      .bind(sinceMs)
      .all<{ day: string; n: number }>(),
    env.DB.prepare("SELECT day, metric, value FROM stats_daily WHERE day >= ? ORDER BY day").bind(since).all<{ day: string; metric: string; value: number }>(),
  ]);
  const feedback: SyncStats["feedback"] = [];
  const snapshots: SyncStats["daily"] = {};
  for (const row of daily.results) {
    if (row.metric.startsWith("feedback:")) {
      feedback.push({ day: row.day, kind: row.metric.slice("feedback:".length), value: row.value });
    } else {
      (snapshots[row.metric] ??= []).push({ day: row.day, value: row.value });
    }
  }
  return {
    generatedAt: new Date(nowMs).toISOString(),
    environment: env.ENVIRONMENT,
    current,
    newAccounts: created.results.map((row) => ({ day: row.day, value: row.n })),
    feedback,
    daily: snapshots,
  };
}

/**
 * Admin entrypoint for the stats page. It has no HTTP route: only a Worker with a
 * service binding to this entrypoint (apps/stats, `entrypoint: "StatsApi"`) can call it,
 * and service bindings only work between Workers of the same Cloudflare account.
 */
export class StatsApi extends WorkerEntrypoint<Env> {
  async stats(): Promise<SyncStats> {
    return collectStats(this.env);
  }
}
