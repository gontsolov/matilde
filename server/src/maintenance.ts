import type { Env } from "./env";

/** Daily cron: drops expired codes, rate counters and sessions. */
export async function cleanupDirectory(env: Env, nowMs = Date.now()): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM email_codes WHERE expires_at < ?").bind(nowMs),
    env.DB.prepare("DELETE FROM rate_counters WHERE expires_at < ?").bind(nowMs),
    env.DB.prepare("DELETE FROM sessions WHERE expires_at < ?").bind(nowMs),
  ]);
}
