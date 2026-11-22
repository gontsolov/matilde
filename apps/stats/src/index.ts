// stats.matilde.page: the owner's private dashboard (docs/stats.md). Every request must carry a
// valid Cloudflare Access JWT for an allowed email; anything else gets a bare 403.
import { accessConfig, verifyAccess } from "./access";
import type { Env } from "./env";
import { renderPage } from "./page";
import { githubDownloads, siteVisits, syncStats, webEvents } from "./sources";

const SECURITY_HEADERS = {
  "Cache-Control": "private, no-store",
  "X-Robots-Tag": "noindex, nofollow",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
};

export interface Deps {
  verify?: typeof verifyAccess;
  fetcher?: typeof fetch;
  cache?: Cache;
  nowMs?: number;
}

export async function handle(request: Request, env: Env, deps: Deps = {}): Promise<Response> {
  const access = await (deps.verify ?? verifyAccess)(request, accessConfig(env));
  if (!access.ok) {
    console.warn(JSON.stringify({ event: "access_denied", reason: access.reason }));
    return new Response("Forbidden\n", { status: 403, headers: { ...SECURITY_HEADERS, "Content-Type": "text/plain; charset=utf-8" } });
  }
  const url = new URL(request.url);
  if (request.method !== "GET" && request.method !== "HEAD") return new Response(null, { status: 405, headers: SECURITY_HEADERS });
  if (url.pathname !== "/") return new Response("Not found\n", { status: 404, headers: { ...SECURITY_HEADERS, "Content-Type": "text/plain; charset=utf-8" } });

  const nowMs = deps.nowMs ?? Date.now();
  const fetcher = deps.fetcher ?? fetch;
  const [events, visits, releases, sync] = await Promise.all([
    webEvents(env, fetcher),
    siteVisits(env, nowMs, fetcher),
    githubDownloads(env, fetcher, deps.cache),
    syncStats(env),
  ]);
  const html = renderPage({ nowMs, events, visits, releases, sync });
  return new Response(request.method === "HEAD" ? null : html, { headers: { ...SECURITY_HEADERS, "Content-Type": "text/html; charset=utf-8" } });
}

export default {
  fetch: (request, env) => handle(request, env, { cache: caches.default }),
} satisfies ExportedHandler<Env>;
