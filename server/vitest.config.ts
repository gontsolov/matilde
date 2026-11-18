import { generateKeyPairSync, randomBytes } from "node:crypto";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Test-only secrets, generated per run. Real secrets are set with `wrangler secret put`.
function testSigningKey(kid: string): string {
  const { privateKey } = generateKeyPairSync("ed25519");
  return JSON.stringify({ ...privateKey.export({ format: "jwk" }), kid });
}

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            ENVIRONMENT: "test",
            MAIL_PROVIDER: "memory",
            TOKEN_SIGNING_KEY: testSigningKey("test-1"),
            OTHER_SIGNING_KEY: testSigningKey("other"),
            CODE_PEPPER: randomBytes(32).toString("base64"),
            TEST_MIGRATIONS: migrations,
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
    },
  };
});
