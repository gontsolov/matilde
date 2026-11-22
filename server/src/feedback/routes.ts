import { Hono } from "hono";
import type { AppEnv } from "../app";
import { verifyAccessToken } from "../auth/tokens";
import { HttpError } from "../util";
import { queuedError, submitFeedback } from "./service";
import { FEEDBACK_LIMITS, parseFeedback } from "./validate";

export const feedbackRoutes = new Hono<AppEnv>();

/**
 * POST /v1/feedback. Works signed out. With a valid access token the issue only
 * says "Signed in: yes"; the account id and email are never looked up or sent.
 */
feedbackRoutes.post("/", async (c) => {
  const declared = Number(c.req.header("Content-Length") ?? 0);
  if (declared > FEEDBACK_LIMITS.maxRequestBytes) throw new HttpError(413, "batch_too_large", "feedback body is too large");
  const text = await c.req.text();
  if (new TextEncoder().encode(text).length > FEEDBACK_LIMITS.maxRequestBytes) throw new HttpError(413, "batch_too_large", "feedback body is too large");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_request", "body must be JSON");
  }
  const input = parseFeedback(body);

  // An expired or invalid token just counts as signed out: feedback must never fail on it.
  const match = /^Bearer ([A-Za-z0-9._-]+)$/.exec(c.req.header("Authorization") ?? "");
  const signedIn = match ? (await verifyAccessToken(c.env, match[1]!)) !== null : false;

  const result = await submitFeedback(c.env, input, { ip: c.req.header("CF-Connecting-IP") ?? "unknown", signedIn });
  if (result.status === "sent") return c.json({ ok: true, id: result.id, status: "sent" }, 201);
  // Stored for retry: the client still learns that delivery didn't happen yet.
  const error = queuedError(result);
  return c.json(
    { error: { code: error.code, message: error.message }, id: result.id, queued: true },
    error.status as 502 | 503,
    { "x-matilde-error": error.code },
  );
});
