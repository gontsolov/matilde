// Facts the pages share. Keep them in step with the app (apps/macos) and the sync server (server/).
export const REPO = "gontsolov/matilde";
/**
 * The Download buttons' link. The Worker (worker/index.ts) adds one anonymous count and redirects
 * to the newest release's Matilde.dmg (the Release workflow always uploads it under that name).
 */
export const DOWNLOAD_URL = "/download";
export const RELEASES_URL = `https://github.com/${REPO}/releases/latest`;
export const SOURCE_URL = `https://github.com/${REPO}`;
/** Where people can reach the owner, e.g. to delete a sync account. OWNER: confirm this address receives mail. */
export const CONTACT_EMAIL = "hello@matilde.page";
/** Feedback by email (footer, and the apps' "Email Instead"). OWNER: route it to your inbox with Cloudflare Email Routing. */
export const FEEDBACK_EMAIL = "feedback@matilde.page";
/** The footer's "Built by Filip" link. */
export const AUTHOR_URL = "https://tsolov.zip";
