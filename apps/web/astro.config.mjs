// @ts-check
import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";

// Static site; served by the Worker in worker/index.ts (see wrangler.jsonc).
export default defineConfig({
  site: "https://matilde.page",
  output: "static",
  trailingSlash: "never",
  build: { format: "file" },
  vite: { plugins: [tailwindcss()] },
});
