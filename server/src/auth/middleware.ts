import { createMiddleware } from "hono/factory";
import type { AppEnv } from "../app";
import { HttpError } from "../util";
import { verifyAccessToken } from "./tokens";

/** Requires `Authorization: Bearer <access token>` and exposes the claims as c.get("auth"). */
export const requireAuth = createMiddleware<AppEnv>(async (c, next) => {
  const header = c.req.header("Authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9._-]+)$/.exec(header);
  const claims = match ? await verifyAccessToken(c.env, match[1]!) : null;
  if (!claims) throw new HttpError(401, "unauthorized", "missing or invalid access token", { "WWW-Authenticate": "Bearer" });
  c.set("auth", claims);
  await next();
});
