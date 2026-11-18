import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      TEST_MIGRATIONS: D1Migration[];
      /** A valid Ed25519 key the server does not trust, for forged-token tests. */
      OTHER_SIGNING_KEY: string;
      /** JSON: [{ name, mailProvider, mailFrom, sendEmail }] for each environment in wrangler.jsonc. */
      TEST_DEPLOYED_MAIL_CONFIG: string;
    }
  }
}
