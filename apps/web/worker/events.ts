// Anonymous daily counts for the stats page (docs/stats.md), written to Workers Analytics Engine.
// A data point holds only the event name, the app version and the macOS major version (both
// coarse, from the update check's user agent). Never an IP, a full user agent or any id.

/** The Analytics Engine dataset (wrangler.jsonc). The stats page queries it by this name. */
export const EVENTS_DATASET = "matilde_web_events";

export type WebEvent = "download" | "appcast";

export interface EventPoint {
  event: WebEvent;
  /** Matilde version from the update check, e.g. "0.3.1"; "" for downloads. */
  version: string;
  /** macOS major version from the update check, e.g. "15"; "" for downloads. */
  os: string;
}

const VERSION_RE = /^Matilde\/((?:0|[1-9]\d{0,3})\.(?:0|[1-9]\d{0,3})\.(?:0|[1-9]\d{0,3}))(?:\s|$)/;
const OS_RE = /\bmacOS\/([1-9]\d?)(?:\s|$)/;
const BOT_RE = /bot|crawl|spider|slurp|preview|facebookexternalhit|curl|wget|python|go-http|headless/i;

/**
 * The coarse facts of an update check. Sparkle sends "Matilde/<version> Sparkle/<version>";
 * the app (from the release after 0.3.2) appends "macOS/<major>". Anything else is "other".
 */
export function parseUpdateCheck(userAgent: string | null): { version: string; os: string } {
  const ua = userAgent ?? "";
  return {
    version: VERSION_RE.exec(ua)?.[1] ?? "other",
    os: OS_RE.exec(ua)?.[1] ?? "unknown",
  };
}

/** Link previews, crawlers and scripts don't count as downloads. */
export function isBot(userAgent: string | null): boolean {
  return !userAgent || BOT_RE.test(userAgent);
}

/** Writes one data point. Analytics Engine writes are fire-and-forget and never fail a request. */
export function record(dataset: AnalyticsEngineDataset | undefined, point: EventPoint): void {
  if (!dataset) return;
  try {
    dataset.writeDataPoint({ indexes: [point.event], blobs: [point.event, point.version, point.os], doubles: [1] });
  } catch {
    // Counting must never break a download or an update check.
  }
}
