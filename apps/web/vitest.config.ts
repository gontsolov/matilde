import { defineConfig } from "vitest/config";

// Unit tests for the Worker (worker/), run in Node. The Astro pages have no tests.
export default defineConfig({ test: { include: ["test/**/*.test.ts"] } });
