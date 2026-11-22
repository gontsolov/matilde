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
  /** Feedback messages per network (/24 or /48) per hour. Default 5. */
  FEEDBACK_PER_IP_HOUR?: string;
  /** Feedback messages per day across all users before refusing more. Default 200. */
  GLOBAL_DAILY_FEEDBACK_CAP?: string;
  /** Linear team that receives feedback issues. Feedback is stored but not delivered while unset. */
  LINEAR_TEAM_ID?: string;
  /** Optional Linear label ids per feedback kind; unset ones are skipped. */
  LINEAR_LABEL_BUG?: string;
  LINEAR_LABEL_IDEA?: string;
  LINEAR_LABEL_OTHER?: string;
  /** Optional Linear label id added to every feedback issue, on top of the kind label. */
  LINEAR_LABEL_FEEDBACK?: string;
  /** Optional Linear project id for feedback issues (issueCreate projectId). */
  LINEAR_PROJECT_ID?: string;
  /** Optional workflow state id for new feedback issues, meant for the team's Triage state. */
  LINEAR_STATE_ID?: string;
  /** "1" serves the MCP server for AI tools (docs/mcp.md) on MCP_ORIGIN; anything else turns it off. */
  MCP_ENABLED: string;
  /** Origin of the MCP host, e.g. "https://mcp.matilde.page". Requests for it go to src/mcp. */
  MCP_ORIGIN: string;

  // Secrets (wrangler secret put)
  /** Ed25519 private JWK (JSON) with a "kid"; signs access tokens. */
  TOKEN_SIGNING_KEY: string;
  /** Optional JSON array of older public JWKs still accepted during key rotation. */
  TOKEN_VERIFY_KEYS?: string;
  /** Random secret (>= 32 bytes, base64) keying the email/code/IP hashes. */
  CODE_PEPPER: string;
  /** Only when MAIL_PROVIDER = "resend" (fallback; not set in the default config). */
  RESEND_API_KEY?: string;
  /** Linear personal API key; creates feedback issues. See docs/feedback.md. */
  LINEAR_API_KEY?: string;
}

type MatildeEnv = Env;

declare global {
  namespace Cloudflare {
    interface Env extends MatildeEnv {}
  }
}
