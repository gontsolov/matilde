import { defineConfig } from "vitest/config";

// Unit tests in Node: Access JWT check, data sources (with fetch stubbed) and the page.
export default defineConfig({ test: { include: ["test/**/*.test.ts"] } });
