// Serves the static site from ./dist, sends www.matilde.page to the apex domain, and answers two
// counted redirects: /download (the latest DMG) and /appcast.xml (Sparkle's update feed). Each of
// those adds one anonymous data point (worker/events.ts); nothing else about the request is kept.
import { isBot, parseUpdateCheck, record } from "./events";

export interface Env {
  ASSETS: Fetcher;
  /** Analytics Engine dataset matilde_web_events (absent in local dev without it). */
  EVENTS?: AnalyticsEngineDataset;
}

const REPO = "gontsolov/matilde";
/** Stable link to the newest DMG; the Release workflow always uploads it as Matilde.dmg. */
export const DMG_URL = `https://github.com/${REPO}/releases/latest/download/Matilde.dmg`;
/** The signed Sparkle feed of the newest release. Signatures are inside the file, so a redirect is safe. */
export const APPCAST_URL = `https://github.com/${REPO}/releases/latest/download/appcast.xml`;

function redirect(location: string): Response {
  // No caching: every click and every update check reaches the Worker and is counted once.
  return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });
}

export async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.hostname === "www.matilde.page") {
    url.hostname = "matilde.page";
    return Response.redirect(url.toString(), 301);
  }
  const counted = request.method === "GET";
  if (url.pathname === "/download") {
    if (counted && !isBot(request.headers.get("User-Agent"))) record(env.EVENTS, { event: "download", version: "", os: "" });
    return redirect(DMG_URL);
  }
  if (url.pathname === "/appcast.xml") {
    if (counted) record(env.EVENTS, { event: "appcast", ...parseUpdateCheck(request.headers.get("User-Agent")) });
    return redirect(APPCAST_URL);
  }
  return env.ASSETS.fetch(request);
}

export default { fetch: handle } satisfies ExportedHandler<Env>;
