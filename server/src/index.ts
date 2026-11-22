import { createApp } from "./app";
import type { Env } from "./env";
import { retryFeedback } from "./feedback/service";
import { cleanupDirectory, isDailyRun } from "./maintenance";
import { isMcpRequest, mcpFetch } from "./mcp";
import { snapshotStats } from "./stats/counters";

export { UserSync } from "./sync/UserSync";
// RPC-only admin entrypoint for the stats page (no HTTP route); see src/stats/api.ts.
export { StatsApi } from "./stats/api";

const app = createApp();

export default {
  fetch(request, env, ctx) {
    // The MCP host (docs/mcp.md) shares this Worker; everything else is the sync API.
    if (isMcpRequest(request, env)) return mcpFetch(request, env, ctx);
    return app.fetch(request, env, ctx);
  },
  async scheduled(controller, env, ctx) {
    if (isDailyRun(controller.scheduledTime)) ctx.waitUntil(cleanupDirectory(env));
    ctx.waitUntil(retryFeedback(env).then(() => undefined));
    ctx.waitUntil(snapshotStats(env, controller.scheduledTime).catch((error) => console.warn(JSON.stringify({ event: "stats_snapshot_failed", name: error instanceof Error ? error.name : "unknown" }))));
  },
} satisfies ExportedHandler<Env>;
