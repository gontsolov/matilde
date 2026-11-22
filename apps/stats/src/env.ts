import type { SyncStats } from "./types";

export interface Env {
  /** Service binding to the production sync server's StatsApi entrypoint. */
  SYNC?: { stats(): Promise<SyncStats> };
  GITHUB_REPO: string;
  EVENTS_DATASET: string;

  // Secrets (wrangler secret put). Missing Access settings keep the page closed.
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  ACCESS_ALLOWED_EMAILS?: string;
  CF_ACCOUNT_ID?: string;
  CF_ANALYTICS_TOKEN?: string;
  WEB_ANALYTICS_SITE_TAG?: string;
}
