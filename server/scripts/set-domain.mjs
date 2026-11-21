#!/usr/bin/env node
// Replaces the placeholder domain in wrangler.jsonc: pnpm run set-domain example.org
import { readFileSync, writeFileSync } from "node:fs";

const PLACEHOLDER = "matilde.example";
const domain = process.argv[2];
if (!domain || !/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(domain)) {
  console.error("usage: pnpm run set-domain <domain>   (e.g. matilde.app)");
  process.exit(1);
}
const path = new URL("../wrangler.jsonc", import.meta.url);
const text = readFileSync(path, "utf8");
const count = text.split(PLACEHOLDER).length - 1;
if (count === 0) {
  console.error(`no "${PLACEHOLDER}" left in wrangler.jsonc; the domain is already set`);
  process.exit(1);
}
writeFileSync(path, text.replaceAll(PLACEHOLDER, domain));
console.log(`replaced ${count} occurrences of ${PLACEHOLDER} with ${domain}`);
