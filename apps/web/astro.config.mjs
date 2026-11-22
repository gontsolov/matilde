// @ts-check
import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import markdown from "./integrations/markdown.mjs";

// Static site; served by the Worker in worker/index.ts (see wrangler.jsonc).
export default defineConfig({
  site: "https://matilde.page",
  output: "static",
  trailingSlash: "never",
  build: { format: "file" },
  // Markdown copies of the pages and llms-full.txt for AI agents (integrations/markdown.mjs).
  integrations: [markdown()],
  vite: { plugins: [tailwindcss()] },
});
