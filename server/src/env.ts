import type { UserSync } from "./sync/UserSync";

/** Bindings, vars and secrets. Keep in sync with wrangler.jsonc and README.md. */
export interface Env {
  DB: D1Database;
  BLOBS: R2Bucket;
  USER_SYNC: DurableObjectNamespace<UserSync>;
  /** Cloudflare Email Service binding (only when MAIL_PROVIDER = "cloudflare"). */
  EMAIL?: SendEmail;

  /** "development" | "test" | "staging" | "production" */
  ENVIRONMENT: string;
  /** "cloudflare" | "resend" | "console" (dev only) | "memory" (tests only) */
  MAIL_PROVIDER: string;
  MAIL_FROM: string;
  /** "eu" in every deployed environment. Empty disables the jurisdiction call. */
  DO_JURISDICTION: string;
  /** Lowest accepted X-Matilde-Build; "0" disables the check. */
  MIN_CLIENT_BUILD: string;
  /** Sign-in codes sent per day across all users before refusing more. */
  GLOBAL_DAILY_CODE_CAP: string;

  // Secrets (wrangler secret put)
  /** Ed25519 private JWK (JSON) with a "kid"; signs access tokens. */
  TOKEN_SIGNING_KEY: string;
  /** Optional JSON array of older public JWKs still accepted during key rotation. */
  TOKEN_VERIFY_KEYS?: string;
  /** Random secret (>= 32 bytes, base64) keying the email/code/IP hashes. */
  CODE_PEPPER: string;
  /** Only when MAIL_PROVIDER = "resend" (fallback; not set in the default config). */
  RESEND_API_KEY?: string;
}

type MatildeEnv = Env;

declare global {
  namespace Cloudflare {
    interface Env extends MatildeEnv {}
  }
}
