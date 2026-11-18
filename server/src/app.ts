import { Hono } from "hono";
import { accountRoutes, authRoutes, deviceRoutes, keyRoutes } from "./auth/routes";
import type { AccessClaims } from "./auth/tokens";
import type { Env } from "./env";
import { blobRoutes, syncRoutes } from "./sync/routes";
import { HttpError } from "./util";

export type AppEnv = { Bindings: Env; Variables: { auth: AccessClaims } };

export const API_VERSION = "v1";

export function createApp(): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // Minimal structured log: never bodies, tokens, codes, emails or IPs.
  app.use("*", async (c, next) => {
    const started = Date.now();
    await next();
    console.log(
      JSON.stringify({
        method: c.req.method,
        route: c.req.routePath,
        status: c.res.status,
        ms: Date.now() - started,
        error: c.res.status >= 400 ? c.res.headers.get("x-matilde-error") : undefined,
      }),
    );
  });

  // Old app builds can be turned away with 426 after a breaking change.
  app.use("/v1/*", async (c, next) => {
    const minimum = Number(c.env.MIN_CLIENT_BUILD || 0);
    if (minimum > 0) {
      const build = Number(c.req.header("X-Matilde-Build") ?? 0);
      if (!Number.isFinite(build) || build < minimum) {
        throw new HttpError(426, "upgrade_required", "this version of Matilde is too old to sync");
      }
    }
    await next();
  });

  app.get("/v1/health", (c) => c.json({ ok: true, api: API_VERSION }));
  app.route("/v1/auth", authRoutes);
  app.route("/v1/devices", deviceRoutes);
  app.route("/v1/account", accountRoutes);
  app.route("/v1/keys", keyRoutes);
  app.route("/v1/sync", syncRoutes);
  app.route("/v1/blobs", blobRoutes);

  app.notFound(() => errorResponse(new HttpError(404, "not_found")));
  app.onError((error) => {
    if (error instanceof HttpError) return errorResponse(error);
    console.error(JSON.stringify({ error: "internal", name: error instanceof Error ? error.name : "unknown", message: error instanceof Error ? error.message : String(error) }));
    return errorResponse(new HttpError(500, "internal_error"));
  });
  return app;
}

export function errorResponse(error: HttpError): Response {
  return new Response(JSON.stringify({ error: { code: error.code, message: error.message } }), {
    status: error.status,
    headers: { "Content-Type": "application/json", "x-matilde-error": error.code, ...error.headers },
  });
}
