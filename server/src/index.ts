import { createApp } from "./app";
import type { Env } from "./env";
import { cleanupDirectory } from "./maintenance";

export { UserSync } from "./sync/UserSync";

const app = createApp();

export default {
  fetch: app.fetch,
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(cleanupDirectory(env));
  },
} satisfies ExportedHandler<Env>;
