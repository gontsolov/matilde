import { createApp } from "./app";
import type { Env } from "./env";

export { UserSync } from "./sync/UserSync";

const app = createApp();

export default {
  fetch: app.fetch,
} satisfies ExportedHandler<Env>;
