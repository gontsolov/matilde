import { ipPrefix, enforceLimits, RateLimitError } from "../auth/ratelimit";
import type { Env } from "../env";
import { HttpError, hmacHex } from "../util";
import { createLinearIssue, type FeedbackPayload, LinearError } from "./linear";
import type { FeedbackInput } from "./validate";

/** Defaults when the vars are unset. */
export const FEEDBACK_DEFAULTS = { perIpHour: 5, globalDay: 200 } as const;

/** Retry policy for rows Linear didn't take. */
export const FEEDBACK_RETRY = {
  /** Rows are left to the request that created them for this long before the cron touches them. */
  minAgeMs: 5 * 60 * 1000,
  /** After this many failed deliveries a row becomes 'failed' and is only kept for manual handling. */
  maxAttempts: 10,
  /** Rows per cron run. */
  batch: 25,
  /** Delivered rows (payload already cleared) are deleted after this long. */
  sentRetentionMs: 30 * 24 * 3600 * 1000,
} as const;

function limit(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return value !== undefined && value !== "" && Number.isFinite(n) && n >= 0 ? n : fallback;
}

export type FeedbackResult =
  | { status: "sent"; id: string; issue: string }
  | { status: "queued"; id: string; reason: string };

/**
 * Rate-limits, stores and delivers one feedback message. The row is written
 * first, so a Linear outage or missing configuration never loses the message.
 */
export async function submitFeedback(env: Env, input: FeedbackInput, context: { ip: string; signedIn: boolean }, nowMs = Date.now()): Promise<FeedbackResult> {
  if (!env.CODE_PEPPER) throw new Error("CODE_PEPPER is not set");
  const network = await hmacHex(env.CODE_PEPPER, `ip:${ipPrefix(context.ip)}`);
  try {
    await enforceLimits(
      env.DB,
      [
        { key: "feedback:global:day", windowSeconds: 86400, max: limit(env.GLOBAL_DAILY_FEEDBACK_CAP, FEEDBACK_DEFAULTS.globalDay) },
        { key: `feedback:ip:${network}`, windowSeconds: 3600, max: limit(env.FEEDBACK_PER_IP_HOUR, FEEDBACK_DEFAULTS.perIpHour) },
      ],
      nowMs,
    );
  } catch (error) {
    if (error instanceof RateLimitError) {
      const event = error.exceeded.includes("feedback:global:day") ? "global_feedback_cap_reached" : "feedback_rate_limited";
      console.warn(JSON.stringify({ event }));
    }
    throw error;
  }

  const payload: FeedbackPayload = { ...input, signedIn: context.signedIn };
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO feedback (id, created_at, updated_at, kind, payload, status, attempts) VALUES (?, ?, ?, ?, ?, 'pending', 0)")
    .bind(id, nowMs, nowMs, input.kind, JSON.stringify(payload))
    .run();

  return deliver(env, id, payload, 0, nowMs);
}

async function deliver(env: Env, id: string, payload: FeedbackPayload, attempts: number, nowMs: number, fetcher?: typeof fetch): Promise<FeedbackResult> {
  try {
    const issue = await createLinearIssue(env, payload, fetcher);
    // Delivered: the text now lives only in Linear.
    await env.DB.prepare("UPDATE feedback SET status = 'sent', payload = NULL, linear_issue = ?, attempts = ?, last_error = NULL, updated_at = ? WHERE id = ?")
      .bind(issue, attempts + 1, nowMs, id)
      .run();
    console.log(JSON.stringify({ event: "feedback_sent" }));
    return { status: "sent", id, issue };
  } catch (error) {
    const reason = error instanceof LinearError ? error.code : "internal";
    const nextAttempts = attempts + 1;
    const status = nextAttempts >= FEEDBACK_RETRY.maxAttempts ? "failed" : "pending";
    await env.DB.prepare("UPDATE feedback SET status = ?, attempts = ?, last_error = ?, updated_at = ? WHERE id = ?")
      .bind(status, nextAttempts, reason, nowMs, id)
      .run();
    console.warn(JSON.stringify({ event: "feedback_queued", reason, status }));
    return { status: "queued", id, reason };
  }
}

/** Daily cron: retries pending rows and drops old delivered ones. */
export async function retryFeedback(env: Env, nowMs = Date.now(), fetcher?: typeof fetch): Promise<{ sent: number; pending: number }> {
  await env.DB.prepare("DELETE FROM feedback WHERE status = 'sent' AND updated_at < ?").bind(nowMs - FEEDBACK_RETRY.sentRetentionMs).run();
  const rows = await env.DB.prepare("SELECT id, payload, attempts FROM feedback WHERE status = 'pending' AND created_at < ? ORDER BY created_at LIMIT ?")
    .bind(nowMs - FEEDBACK_RETRY.minAgeMs, FEEDBACK_RETRY.batch)
    .all<{ id: string; payload: string | null; attempts: number }>();
  let sent = 0;
  let pending = 0;
  for (const row of rows.results) {
    if (!row.payload) continue;
    const result = await deliver(env, row.id, JSON.parse(row.payload) as FeedbackPayload, row.attempts, nowMs, fetcher);
    if (result.status === "sent") sent += 1;
    else pending += 1;
    // Linear is unreachable or not configured: don't hammer it with the rest of the batch.
    if (result.status === "queued" && (result.reason === "not_configured" || result.reason.startsWith("http_4"))) break;
  }
  return { sent, pending };
}

/** The error a client gets when its message was stored but not delivered yet. */
export function queuedError(result: Extract<FeedbackResult, { status: "queued" }>): HttpError {
  return result.reason === "not_configured"
    ? new HttpError(503, "feedback_not_configured", "feedback delivery is not set up yet; the message was saved and will be delivered later")
    : new HttpError(502, "feedback_delivery_failed", "feedback could not be delivered right now; the message was saved and will be retried");
}
