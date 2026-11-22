import type { Env } from "./env";

/** Daily cron: drops expired codes, rate counters and sessions. */
export async function cleanupDirectory(env: Env, nowMs = Date.now()): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM email_codes WHERE expires_at < ?").bind(nowMs),
    env.DB.prepare("DELETE FROM rate_counters WHERE expires_at < ?").bind(nowMs),
    env.DB.prepare("DELETE FROM sessions WHERE expires_at < ?").bind(nowMs),
  ]);
}

/** The cron fires every 15 minutes (feedback retries); directory cleanup runs once, at 03:15 UTC. */
export function isDailyRun(scheduledTime: number): boolean {
  const at = new Date(scheduledTime);
  return at.getUTCHours() === 3 && at.getUTCMinutes() >= 15 && at.getUTCMinutes() < 30;
}
