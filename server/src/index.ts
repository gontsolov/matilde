import { createApp } from "./app";
import type { Env } from "./env";
import { retryFeedback } from "./feedback/service";
import { cleanupDirectory, isDailyRun } from "./maintenance";
import { snapshotStats } from "./stats/counters";

export { UserSync } from "./sync/UserSync";
// RPC-only admin entrypoint for the stats page (no HTTP route); see src/stats/api.ts.
export { StatsApi } from "./stats/api";

const app = createApp();

export default {
  fetch: app.fetch,
  async scheduled(controller, env, ctx) {
    if (isDailyRun(controller.scheduledTime)) ctx.waitUntil(cleanupDirectory(env));
    ctx.waitUntil(retryFeedback(env).then(() => undefined));
    ctx.waitUntil(snapshotStats(env, controller.scheduledTime).catch((error) => console.warn(JSON.stringify({ event: "stats_snapshot_failed", name: error instanceof Error ? error.name : "unknown" }))));
  },
} satisfies ExportedHandler<Env>;
