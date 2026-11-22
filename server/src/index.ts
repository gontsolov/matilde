import { createApp } from "./app";
import type { Env } from "./env";
import { retryFeedback } from "./feedback/service";
import { cleanupDirectory, isDailyRun } from "./maintenance";

export { UserSync } from "./sync/UserSync";

const app = createApp();

export default {
  fetch: app.fetch,
  async scheduled(controller, env, ctx) {
    if (isDailyRun(controller.scheduledTime)) ctx.waitUntil(cleanupDirectory(env));
    ctx.waitUntil(retryFeedback(env).then(() => undefined));
  },
} satisfies ExportedHandler<Env>;
