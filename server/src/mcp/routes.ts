// /v1/connections on the sync host: the apps' "Connected AI tools" list. Signed-in devices only.

import { Hono } from "hono";
import type { AppEnv } from "../app";
import { requireAuth } from "../auth/middleware";
import { HttpError, UUID_RE } from "../util";
import { activeConnections, connectionView, revokeGrantRow } from "./grants";
import { oauthHelpers } from "./index";

export const connectionRoutes = new Hono<AppEnv>();
connectionRoutes.use("*", requireAuth);

connectionRoutes.get("/", async (c) => {
  const { userId } = c.get("auth");
  const rows = await activeConnections(c.env, userId);
  return c.json({ connections: rows.map(connectionView) });
});

connectionRoutes.get("/:id/activity", async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) throw new HttpError(404, "not_found");
  const owned = await c.env.DB.prepare("SELECT id FROM mcp_grants WHERE id = ? AND user_id = ?").bind(id, userId).first();
  if (!owned) throw new HttpError(404, "not_found");
  const rows = await c.env.DB.prepare("SELECT at, tool, outcome FROM mcp_audit WHERE grant_id = ? AND user_id = ? ORDER BY at DESC LIMIT 100")
    .bind(id, userId)
    .all<{ at: number; tool: string; outcome: string }>();
  return c.json({ activity: rows.results });
});

connectionRoutes.delete("/:id", async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) throw new HttpError(404, "not_found");
  const row = await revokeGrantRow(c.env, userId, id);
  if (!row) throw new HttpError(404, "not_found");
  // The D1 row is what every call checks, so the connection is already dead. Also drop the
  // OAuth grant and its tokens so the tool can't refresh.
  if (c.env.MCP_ORIGIN) {
    try {
      const helpers = oauthHelpers(c.env);
      let cursor: string | undefined;
      do {
        const page = await helpers.listUserGrants(userId, { cursor });
        for (const grant of page.items) {
          if (grant.metadata?.grantId === id) await helpers.revokeGrant(grant.id, userId);
        }
        cursor = page.cursor;
      } while (cursor);
    } catch (error) {
      console.error(JSON.stringify({ event: "mcp_revoke_oauth_failed", name: error instanceof Error ? error.name : "unknown" }));
    }
  }
  return c.body(null, 204);
});
