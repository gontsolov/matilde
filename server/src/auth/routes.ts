import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import type { AppEnv } from "../app";
import { userSync } from "../sync/stub";
import { base64ToBytes, HttpError, UUID_RE } from "../util";
import { startEmailSignIn, verifyEmailCode } from "./email";
import { requireAuth } from "./middleware";
import { listDevices, PLATFORMS, refreshSession, revokeSession } from "./sessions";

async function jsonBody(c: { req: { json: () => Promise<unknown> } }): Promise<Record<string, unknown>> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    throw new HttpError(400, "invalid_request", "body must be JSON");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw new HttpError(400, "invalid_request", "body must be an object");
  return body as Record<string, unknown>;
}

function clientIp(c: { req: { header: (name: string) => string | undefined } }): string {
  return c.req.header("CF-Connecting-IP") ?? "unknown";
}

function optionalNameCt(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || value.length > 512 || !base64ToBytes(value)) {
    throw new HttpError(400, "invalid_request", "deviceNameCt must be base64 (at most 512 characters)");
  }
  return value;
}

/** For destructive actions: the access token's session must still exist (not revoked). */
const requireLiveSession = createMiddleware<AppEnv>(async (c, next) => {
  const { userId, sessionId } = c.get("auth");
  const row = await c.env.DB.prepare("SELECT 1 AS ok FROM sessions WHERE id = ? AND account_id = ?").bind(sessionId, userId).first();
  if (!row) throw new HttpError(401, "session_revoked", "sign in again");
  await next();
});

// MARK: sign-in

export const authRoutes = new Hono<AppEnv>();

authRoutes.post("/email/start", async (c) => {
  const body = await jsonBody(c);
  await startEmailSignIn(c.env, body.email, clientIp(c));
  return c.json({ ok: true, expiresIn: 600 }, 202);
});

authRoutes.post("/email/verify", async (c) => {
  const body = await jsonBody(c);
  const { deviceId, platform } = body;
  if (typeof deviceId !== "string" || !UUID_RE.test(deviceId)) throw new HttpError(400, "invalid_request", "deviceId must be a lowercase UUID");
  if (typeof platform !== "string" || !PLATFORMS.has(platform)) throw new HttpError(400, "invalid_request", "unknown platform");
  const result = await verifyEmailCode(
    c.env,
    { email: body.email, code: body.code, deviceId, platform, nameCt: optionalNameCt(body.deviceNameCt) },
    clientIp(c),
  );
  return c.json(result);
});

authRoutes.post("/refresh", async (c) => {
  const body = await jsonBody(c);
  if (typeof body.refreshToken !== "string") throw new HttpError(400, "invalid_request", "refreshToken is required");
  return c.json(await refreshSession(c.env, body.refreshToken));
});

authRoutes.post("/logout", requireAuth, async (c) => {
  const { userId, sessionId } = c.get("auth");
  await revokeSession(c.env, userId, sessionId);
  return c.body(null, 204);
});

// MARK: devices

export const deviceRoutes = new Hono<AppEnv>();
deviceRoutes.use("*", requireAuth);

deviceRoutes.get("/", async (c) => {
  const { userId, sessionId } = c.get("auth");
  return c.json({ devices: await listDevices(c.env, userId, sessionId) });
});

deviceRoutes.patch("/:sessionId", requireLiveSession, async (c) => {
  const { userId } = c.get("auth");
  const body = await jsonBody(c);
  const result = await c.env.DB.prepare("UPDATE sessions SET name_ct = ? WHERE id = ? AND account_id = ?")
    .bind(optionalNameCt(body.deviceNameCt), c.req.param("sessionId"), userId)
    .run();
  if (result.meta.changes === 0) throw new HttpError(404, "not_found");
  return c.body(null, 204);
});

deviceRoutes.delete("/:sessionId", requireLiveSession, async (c) => {
  const { userId } = c.get("auth");
  if (!(await revokeSession(c.env, userId, c.req.param("sessionId")))) throw new HttpError(404, "not_found");
  return c.body(null, 204);
});

// MARK: account

export const accountRoutes = new Hono<AppEnv>();
accountRoutes.use("*", requireAuth);

accountRoutes.get("/", async (c) => {
  const { userId } = c.get("auth");
  const account = await c.env.DB.prepare("SELECT id, created_at, key_id, key_check FROM accounts WHERE id = ?")
    .bind(userId)
    .first<{ id: string; created_at: number; key_id: number | null; key_check: string | null }>();
  if (!account) throw new HttpError(404, "not_found");
  const identities = await c.env.DB.prepare("SELECT provider, email, created_at FROM identities WHERE account_id = ?")
    .bind(userId)
    .all<{ provider: string; email: string | null; created_at: number }>();
  return c.json({
    userId: account.id,
    createdAt: account.created_at,
    identities: identities.results.map((i) => ({ provider: i.provider, email: i.email, createdAt: i.created_at })),
  });
});

/** Deletes all server data of the account: records, blobs, sessions, identities, key slots. */
accountRoutes.delete("/", requireLiveSession, async (c) => {
  const { userId } = c.get("auth");
  const body = await jsonBody(c);
  if (body.confirm !== "delete my account") throw new HttpError(400, "invalid_request", 'confirm must be "delete my account"');
  await userSync(c.env, userId).deleteAccount(userId);
  await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM key_slots WHERE account_id = ?").bind(userId),
    c.env.DB.prepare("DELETE FROM sessions WHERE account_id = ?").bind(userId),
    c.env.DB.prepare("DELETE FROM identities WHERE account_id = ?").bind(userId),
    c.env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(userId),
  ]);
  return c.body(null, 204);
});

// MARK: key slots (storage only; the crypto is SYNC-06)

export const keyRoutes = new Hono<AppEnv>();
keyRoutes.use("*", requireAuth);

const SLOT_KINDS = /^[a-z][a-z0-9-]{0,31}$/;

keyRoutes.get("/", async (c) => {
  const { userId } = c.get("auth");
  const account = await c.env.DB.prepare("SELECT key_id, key_check FROM accounts WHERE id = ?")
    .bind(userId)
    .first<{ key_id: number | null; key_check: string | null }>();
  if (!account) throw new HttpError(404, "not_found");
  const slots = await c.env.DB.prepare("SELECT slot_id, kind, key_id, params, wrapped_key, updated_at FROM key_slots WHERE account_id = ? ORDER BY slot_id")
    .bind(userId)
    .all<{ slot_id: string; kind: string; key_id: number; params: string | null; wrapped_key: string; updated_at: number }>();
  return c.json({
    keyId: account.key_id,
    keyCheck: account.key_check,
    slots: slots.results.map((s) => ({ slotId: s.slot_id, kind: s.kind, keyId: s.key_id, params: s.params, wrappedKey: s.wrapped_key, updatedAt: s.updated_at })),
  });
});

/**
 * Replaces the key check value and all slots at once. `expectedKeyId` must
 * match the stored key id (null when none exists yet), so two devices that
 * turn on sync at the same time can't both create an account key.
 */
keyRoutes.put("/", requireLiveSession, async (c) => {
  const { userId } = c.get("auth");
  const body = await jsonBody(c);
  const { expectedKeyId, keyId, keyCheck, slots } = body;
  const isKeyId = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= 0xffff;
  if (expectedKeyId !== null && !isKeyId(expectedKeyId)) throw new HttpError(400, "invalid_request", "expectedKeyId must be null or a key id");
  if (!isKeyId(keyId)) throw new HttpError(400, "invalid_request", "keyId must be a positive integer");
  if (typeof keyCheck !== "string" || keyCheck.length > 128 || !base64ToBytes(keyCheck)) throw new HttpError(400, "invalid_request", "keyCheck must be base64");
  if (!Array.isArray(slots) || slots.length === 0 || slots.length > 8) throw new HttpError(400, "invalid_request", "slots must have 1 to 8 entries");
  const now = Date.now();
  const parsed = slots.map((slot: unknown) => {
    const s = slot as Record<string, unknown>;
    if (typeof s?.slotId !== "string" || !UUID_RE.test(s.slotId)) throw new HttpError(400, "invalid_request", "slotId must be a lowercase UUID");
    if (typeof s.kind !== "string" || !SLOT_KINDS.test(s.kind)) throw new HttpError(400, "invalid_request", "invalid slot kind");
    if (s.params !== undefined && s.params !== null && (typeof s.params !== "string" || s.params.length > 1024)) throw new HttpError(400, "invalid_request", "params must be a string of at most 1024 characters");
    if (typeof s.wrappedKey !== "string" || s.wrappedKey.length > 1024 || !base64ToBytes(s.wrappedKey)) throw new HttpError(400, "invalid_request", "wrappedKey must be base64");
    return { slotId: s.slotId, kind: s.kind, params: (s.params as string | null | undefined) ?? null, wrappedKey: s.wrappedKey };
  });
  const cas = await c.env.DB.prepare(
    "UPDATE accounts SET key_id = ?, key_check = ? WHERE id = ? AND key_id IS ?",
  )
    .bind(keyId, keyCheck, userId, expectedKeyId)
    .run();
  if (cas.meta.changes !== 1) throw new HttpError(409, "key_conflict", "the account key changed; fetch it and try again");
  await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM key_slots WHERE account_id = ?").bind(userId),
    ...parsed.map((s) =>
      c.env.DB.prepare("INSERT INTO key_slots (account_id, slot_id, kind, key_id, params, wrapped_key, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)").bind(
        userId,
        s.slotId,
        s.kind,
        keyId,
        s.params,
        s.wrappedKey,
        now,
      ),
    ),
  ]);
  return c.json({ keyId });
});
