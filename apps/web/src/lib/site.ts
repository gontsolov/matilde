// Facts the pages share. Keep them in step with the app (apps/macos) and the sync server (server/).
export const REPO = "gontsolov/matilde";
/** Stable link to the newest DMG; the Release workflow always uploads it as Matilde.dmg. */
export const DOWNLOAD_URL = `https://github.com/${REPO}/releases/latest/download/Matilde.dmg`;
export const RELEASES_URL = `https://github.com/${REPO}/releases/latest`;
export const SOURCE_URL = `https://github.com/${REPO}`;
/** LSMinimumSystemVersion in apps/macos/scripts/write-info.py; arm64-only since 0.1.9. */
export const PLATFORM = "Apple silicon · macOS 14 or later";
/** Where people can reach the owner, e.g. to delete a sync account. OWNER: confirm this address receives mail. */
export const CONTACT_EMAIL = "hello@matilde.page";
/** The footer's "Built by Filip" link. */
export const AUTHOR_URL = "https://tsolov.zip";
