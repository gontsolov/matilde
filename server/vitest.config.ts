import { generateKeyPairSync, randomBytes } from "node:crypto";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { experimental_readRawConfig } from "wrangler";
import { defineConfig } from "vitest/config";

// Test-only secrets, generated per run. Real secrets are set with `wrangler secret put`.
function testSigningKey(kid: string): string {
  const { privateKey } = generateKeyPairSync("ed25519");
  return JSON.stringify({ ...privateKey.export({ format: "jwk" }), kid });
}

// Mail settings of the deployed environments, so test/mailer.test.ts can check that the
// send_email binding can reach arbitrary recipients (no destination restriction).
function deployedMailConfig(): string {
  const { rawConfig } = experimental_readRawConfig({ config: "./wrangler.jsonc" });
  const envs = Object.entries(rawConfig.env ?? {}).map(([name, env]) => ({
    name,
    mailProvider: env.vars?.MAIL_PROVIDER,
    mailFrom: env.vars?.MAIL_FROM,
    sendEmail: env.send_email ?? [],
  }));
  return JSON.stringify(envs);
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
            TEST_DEPLOYED_MAIL_CONFIG: deployedMailConfig(),
            // Feedback: a fake Linear config; test/feedback.test.ts stubs fetch to api.linear.app.
            LINEAR_API_KEY: "lin_api_test",
            LINEAR_TEAM_ID: "team-test",
            LINEAR_LABEL_BUG: "label-bug",
            LINEAR_LABEL_IDEA: "label-idea",
            LINEAR_LABEL_OTHER: "",
            LINEAR_LABEL_FEEDBACK: "label-feedback",
            GLOBAL_DAILY_FEEDBACK_CAP: "100000",
            // MCP server (docs/mcp.md), reached as https://mcp.test in test/mcp.test.ts.
            MCP_ENABLED: "1",
            MCP_ORIGIN: "https://mcp.test",
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
    },
  };
});
