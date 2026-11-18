import type { Env } from "../env";
import { userSync } from "../sync/stub";
import { base64UrlToBytes, bytesToBase64Url, HttpError, randomBytes, sha256Hex, timingSafeEqual, utcDay } from "../util";
import { LIMITS } from "../limits";
import { ACCESS_TOKEN_TTL_SECONDS, signAccessToken } from "./tokens";

/** Refresh tokens expire after 90 days without use. */
export const REFRESH_TTL_MS = 90 * 24 * 3600 * 1000;
/**
 * A just-rotated refresh token is accepted again for this long, so a client
 * whose refresh response got lost can retry. Any older token, or the previous
 * one after the grace, counts as reuse and revokes the session.
 */
export const REFRESH_RETRY_GRACE_MS = 30 * 1000;

const TOKEN_PREFIX = "mrt1";

export const PLATFORMS = new Set(["macos", "ios", "ipados", "web", "android", "other"]);

export interface TokenPair {
  accessToken: string;
  accessTokenExpiresIn: number;
  refreshToken: string;
  sessionId: string;
  userId: string;
}

interface SessionRow {
  id: string;
  account_id: string;
  device_id: string;
  refresh_hash: string;
  prev_refresh_hash: string | null;
  rotated_at: number;
  expires_at: number;
}

function newRefreshSecret(): { token: (sessionId: string) => string; secret: string } {
  const secret = bytesToBase64Url(randomBytes(32));
  return { secret, token: (sessionId) => `${TOKEN_PREFIX}.${sessionId}.${secret}` };
}

function parseRefreshToken(token: string): { sessionId: string; secret: string } | null {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== TOKEN_PREFIX) return null;
  const [, sessionId, secret] = parts as [string, string, string];
  if (!/^[0-9a-f-]{36}$/.test(sessionId)) return null;
  const bytes = base64UrlToBytes(secret);
  if (!bytes || bytes.length !== 32) return null;
  return { sessionId, secret };
}

export interface NewSession {
  userId: string;
  deviceId: string;
  platform: string;
  nameCt: string | null;
}

/** Creates (or replaces, for the same device) a session and returns its first token pair. */
export async function createSession(env: Env, input: NewSession, nowMs = Date.now()): Promise<TokenPair> {
  const existing = await env.DB.prepare("SELECT id, device_id FROM sessions WHERE account_id = ?")
    .bind(input.userId)
    .all<{ id: string; device_id: string }>();
  const sameDevice = existing.results.find((s) => s.device_id === input.deviceId);
  const others = existing.results.length - (sameDevice ? 1 : 0);
  if (others >= LIMITS.maxDevices) {
    throw new HttpError(403, "device_limit", `at most ${LIMITS.maxDevices} devices; remove one in Settings on another device`);
  }
  const sessionId = crypto.randomUUID();
  const refresh = newRefreshSecret();
  const statements = [];
  if (sameDevice) statements.push(env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(sameDevice.id));
  statements.push(
    env.DB.prepare(
      `INSERT INTO sessions (id, account_id, device_id, platform, name_ct, refresh_hash, prev_refresh_hash, rotated_at, created_at, last_seen_day, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)`,
    ).bind(
      sessionId,
      input.userId,
      input.deviceId,
      input.platform,
      input.nameCt,
      await sha256Hex(refresh.secret),
      nowMs,
      nowMs,
      utcDay(nowMs),
      nowMs + REFRESH_TTL_MS,
    ),
  );
  await env.DB.batch(statements);
  if (sameDevice) await userSync(env, input.userId).closeSession(sameDevice.id);
  return {
    accessToken: await signAccessToken(env, { userId: input.userId, sessionId, deviceId: input.deviceId }, nowMs),
    accessTokenExpiresIn: ACCESS_TOKEN_TTL_SECONDS,
    refreshToken: refresh.token(sessionId),
    sessionId,
    userId: input.userId,
  };
}

const invalidRefresh = () => new HttpError(401, "invalid_refresh_token", "sign in again");

/** Rotates a refresh token. Presenting an already-rotated token revokes the whole session. */
export async function refreshSession(env: Env, token: string, nowMs = Date.now()): Promise<TokenPair> {
  const parsed = parseRefreshToken(token);
  if (!parsed) throw invalidRefresh();
  const session = await env.DB.prepare(
    "SELECT id, account_id, device_id, refresh_hash, prev_refresh_hash, rotated_at, expires_at FROM sessions WHERE id = ?",
  )
    .bind(parsed.sessionId)
    .first<SessionRow>();
  if (!session) throw invalidRefresh();
  if (session.expires_at < nowMs) {
    await revokeSession(env, session.account_id, session.id);
    throw invalidRefresh();
  }
  const presented = await sha256Hex(parsed.secret);
  const isCurrent = timingSafeEqual(presented, session.refresh_hash);
  const isRetry =
    !isCurrent &&
    session.prev_refresh_hash !== null &&
    timingSafeEqual(presented, session.prev_refresh_hash) &&
    nowMs - session.rotated_at <= REFRESH_RETRY_GRACE_MS;
  if (!isCurrent && !isRetry) {
    // Reuse of a rotated token: someone else may hold a copy. Kill the session.
    await revokeSession(env, session.account_id, session.id);
    throw new HttpError(401, "refresh_token_reused", "this session was signed out for safety; sign in again");
  }
  const next = newRefreshSecret();
  const nextHash = await sha256Hex(next.secret);
  // Compare-and-swap on the hash we just read, so two concurrent refreshes can't both win.
  // A retry keeps the original rotation time, so the grace window never extends itself.
  const previous = isCurrent ? session.refresh_hash : session.prev_refresh_hash;
  const rotatedAt = isCurrent ? nowMs : session.rotated_at;
  const update = await env.DB.prepare(
    `UPDATE sessions SET refresh_hash = ?, prev_refresh_hash = ?, rotated_at = ?, last_seen_day = ?, expires_at = ?
     WHERE id = ? AND refresh_hash = ?`,
  )
    .bind(nextHash, previous, rotatedAt, utcDay(nowMs), nowMs + REFRESH_TTL_MS, session.id, session.refresh_hash)
    .run();
  if (update.meta.changes !== 1) throw invalidRefresh();
  return {
    accessToken: await signAccessToken(env, { userId: session.account_id, sessionId: session.id, deviceId: session.device_id }, nowMs),
    accessTokenExpiresIn: ACCESS_TOKEN_TTL_SECONDS,
    refreshToken: next.token(session.id),
    sessionId: session.id,
    userId: session.account_id,
  };
}

/** Deletes a session (refresh fails at once; access tokens expire within 15 minutes) and closes its sockets. */
export async function revokeSession(env: Env, userId: string, sessionId: string): Promise<boolean> {
  const result = await env.DB.prepare("DELETE FROM sessions WHERE id = ? AND account_id = ?").bind(sessionId, userId).run();
  if (result.meta.changes > 0) await userSync(env, userId).closeSession(sessionId);
  return result.meta.changes > 0;
}

export interface DeviceInfo {
  sessionId: string;
  deviceId: string;
  platform: string;
  nameCt: string | null;
  createdAt: number;
  lastSeenDay: string;
  current: boolean;
}

export async function listDevices(env: Env, userId: string, currentSessionId: string): Promise<DeviceInfo[]> {
  const rows = await env.DB.prepare(
    "SELECT id, device_id, platform, name_ct, created_at, last_seen_day FROM sessions WHERE account_id = ? ORDER BY created_at",
  )
    .bind(userId)
    .all<{ id: string; device_id: string; platform: string; name_ct: string | null; created_at: number; last_seen_day: string }>();
  return rows.results.map((row) => ({
    sessionId: row.id,
    deviceId: row.device_id,
    platform: row.platform,
    nameCt: row.name_ct,
    createdAt: row.created_at,
    lastSeenDay: row.last_seen_day,
    current: row.id === currentSessionId,
  }));
}
