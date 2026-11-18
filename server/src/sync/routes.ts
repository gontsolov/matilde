import { Hono } from "hono";
import type { AppEnv } from "../app";
import { requireAuth } from "../auth/middleware";
import { LIMITS } from "../limits";
import { HttpError, UUID_RE } from "../util";
import { userSync } from "./stub";
import type { AccountGone } from "./types";

/** Unwraps a Durable Object result; a deleted account answers 410. */
function present<T extends object>(result: T): Exclude<T, AccountGone> {
  if ("gone" in result) throw new HttpError(410, "account_deleted");
  return result as Exclude<T, AccountGone>;
}
import { parsePush } from "./validate";

export const syncRoutes = new Hono<AppEnv>();

syncRoutes.use("*", requireAuth);

syncRoutes.post("/push", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const length = Number(c.req.header("Content-Length") ?? 0);
  if (length > LIMITS.pushMaxRequestBytes) throw new HttpError(413, "batch_too_large");
  const text = await c.req.text();
  if (text.length > LIMITS.pushMaxRequestBytes) throw new HttpError(413, "batch_too_large");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_request", "body must be JSON");
  }
  const changes = parsePush(body, deviceId);
  return c.json(present(await userSync(c.env, userId).push(userId, deviceId, changes)));
});

syncRoutes.get("/pull", async (c) => {
  const { userId } = c.get("auth");
  const since = Number(c.req.query("since") ?? "0");
  const limit = Number(c.req.query("limit") ?? LIMITS.pullDefaultLimit);
  if (!Number.isSafeInteger(since) || since < 0) throw new HttpError(400, "invalid_request", "since must be a non-negative integer");
  if (!Number.isSafeInteger(limit) || limit < 1) throw new HttpError(400, "invalid_request", "limit must be a positive integer");
  return c.json(present(await userSync(c.env, userId).pull(userId, since, Math.min(limit, LIMITS.pullMaxLimit))));
});

syncRoutes.get("/ws", async (c) => {
  const { userId, deviceId, sessionId } = c.get("auth");
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") throw new HttpError(426, "websocket_required");
  const headers = new Headers({
    Upgrade: "websocket",
    "x-matilde-user": userId,
    "x-matilde-device": deviceId,
    "x-matilde-session": sessionId,
  });
  return userSync(c.env, userId).fetch(new Request("https://user-sync/ws", { headers }));
});

export const blobRoutes = new Hono<AppEnv>();

blobRoutes.use("*", requireAuth);

function blobKey(userId: string, blobId: string): string {
  return `u/${userId}/b/${blobId}`;
}

function checkBlobId(blobId: string): string {
  if (!UUID_RE.test(blobId)) throw new HttpError(400, "invalid_request", "blob id must be a lowercase UUID");
  return blobId;
}

blobRoutes.put("/:blobId", async (c) => {
  const { userId } = c.get("auth");
  const blobId = checkBlobId(c.req.param("blobId"));
  const lengthHeader = c.req.header("Content-Length");
  const size = Number(lengthHeader);
  if (!lengthHeader || !Number.isSafeInteger(size) || size < 1) throw new HttpError(411, "length_required");
  if (size > LIMITS.blobMaxBytes) throw new HttpError(413, "blob_too_large");
  const stub = userSync(c.env, userId);
  const info = present(await stub.blobInfo(userId, blobId));
  if (info.exists) return c.json({ blobId, size: info.size, existed: true });
  if (size > info.quotaLeft) throw new HttpError(413, "quota_exceeded");
  const body = c.req.raw.body;
  if (!body) throw new HttpError(400, "invalid_request", "empty body");
  const stored = await c.env.BLOBS.put(blobKey(userId, blobId), body.pipeThrough(new FixedLengthStream(size)));
  if (!stored || stored.size !== size) throw new HttpError(400, "invalid_request", "body length mismatch");
  const commit = present(await stub.commitBlob(userId, blobId, size));
  if (!commit.ok) {
    await c.env.BLOBS.delete(blobKey(userId, blobId));
    throw new HttpError(413, "quota_exceeded");
  }
  return c.json({ blobId, size, existed: commit.existed }, commit.existed ? 200 : 201);
});

blobRoutes.get("/:blobId", async (c) => {
  const { userId } = c.get("auth");
  const blobId = checkBlobId(c.req.param("blobId"));
  const object = await c.env.BLOBS.get(blobKey(userId, blobId));
  if (!object) throw new HttpError(404, "not_found");
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(object.size),
      "Cache-Control": "private, no-store",
    },
  });
});
