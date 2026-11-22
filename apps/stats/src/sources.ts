// The page's data sources. Each one fails on its own: the page shows what it could load and
// says which source is missing, instead of failing as a whole.
import type { Env } from "./env";
import type { DayValue, SyncStats } from "./types";

export const DAYS = 30;
const CF_API = "https://api.cloudflare.com/client/v4";

/** `warning`: the value is usable but not current (e.g. a cached copy served after an error). */
export type Result<T> = { ok: true; value: T; warning?: string } | { ok: false; error: string };

async function attempt<T>(work: () => Promise<T>): Promise<Result<T>> {
  try {
    return { ok: true, value: await work() };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

// MARK: Analytics Engine (matilde-web's /download and /appcast.xml counts)

export interface EventRow {
  day: string;
  event: string;
  version: string;
  os: string;
  count: number;
}

const DATASET_RE = /^[a-z_][a-z0-9_]*$/;

export function eventsQuery(dataset: string, days = DAYS): string {
  if (!DATASET_RE.test(dataset)) throw new Error("invalid dataset name");
  // _sample_interval: Analytics Engine may sample at high volume; this restores the count.
  return `SELECT toStartOfInterval(timestamp, INTERVAL '1' DAY) AS day, blob1 AS event, blob2 AS version, blob3 AS os,
  SUM(_sample_interval) AS count
FROM ${dataset}
WHERE timestamp > NOW() - INTERVAL '${days}' DAY
GROUP BY day, event, version, os
ORDER BY day
FORMAT JSON`;
}

export async function webEvents(env: Env, fetcher: typeof fetch = fetch): Promise<Result<EventRow[]>> {
  return attempt(async () => {
    if (!env.CF_ACCOUNT_ID || !env.CF_ANALYTICS_TOKEN) throw new Error("CF_ACCOUNT_ID or CF_ANALYTICS_TOKEN is not set");
    const res = await fetcher(`${CF_API}/accounts/${encodeURIComponent(env.CF_ACCOUNT_ID)}/analytics_engine/sql`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.CF_ANALYTICS_TOKEN}` },
      body: eventsQuery(env.EVENTS_DATASET),
    });
    if (!res.ok) throw new Error(`Analytics Engine answered ${res.status}`);
    const body = (await res.json()) as { data?: Record<string, unknown>[] };
    return (body.data ?? []).map((row) => ({
      day: String(row.day ?? "").slice(0, 10),
      event: String(row.event ?? ""),
      version: String(row.version ?? ""),
      os: String(row.os ?? ""),
      count: Number(row.count ?? 0),
    }));
  });
}

// MARK: Web Analytics (visits)

export const VISITS_QUERY = `query Visits($accountTag: string!, $siteTag: string!, $since: Date!, $until: Date!) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      rumPageloadEventsAdaptiveGroups(
        limit: 100
        filter: { siteTag: $siteTag, date_geq: $since, date_leq: $until }
        orderBy: [date_ASC]
      ) {
        count
        sum { visits }
        dimensions { date }
      }
    }
  }
}`;

export interface VisitDay {
  day: string;
  visits: number;
  pageViews: number;
}

export async function siteVisits(env: Env, nowMs = Date.now(), fetcher: typeof fetch = fetch): Promise<Result<VisitDay[]> | null> {
  if (!env.WEB_ANALYTICS_SITE_TAG) return null;
  return attempt(async () => {
    if (!env.CF_ACCOUNT_ID || !env.CF_ANALYTICS_TOKEN) throw new Error("CF_ACCOUNT_ID or CF_ANALYTICS_TOKEN is not set");
    const res = await fetcher(`${CF_API}/graphql`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.CF_ANALYTICS_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        query: VISITS_QUERY,
        variables: {
          accountTag: env.CF_ACCOUNT_ID,
          siteTag: env.WEB_ANALYTICS_SITE_TAG,
          since: utcDay(nowMs - (DAYS - 1) * DAY_MS),
          until: utcDay(nowMs),
        },
      }),
    });
    if (!res.ok) throw new Error(`GraphQL Analytics answered ${res.status}`);
    type Group = { count: number; sum: { visits: number }; dimensions: { date: string } };
    const body = (await res.json()) as { data?: { viewer?: { accounts?: { rumPageloadEventsAdaptiveGroups?: Group[] }[] } }; errors?: { message: string }[] | null };
    if (body.errors?.length) throw new Error(`GraphQL Analytics: ${body.errors[0]!.message}`);
    const groups = body.data?.viewer?.accounts?.[0]?.rumPageloadEventsAdaptiveGroups ?? [];
    return groups.map((g) => ({ day: g.dimensions.date, visits: Number(g.sum.visits), pageViews: Number(g.count) }));
  });
}

// MARK: GitHub release downloads

export interface ReleaseDownloads {
  tag: string;
  publishedAt: string;
  /** Matilde.dmg downloads: new downloads plus Sparkle updates (both fetch this file). */
  dmg: number;
  /** appcast.xml fetches straight from GitHub: update checks from installs on the old feed URL. */
  appcast: number;
}

const GITHUB_CACHE_SECONDS = 3600;
/** How long the last good answer is kept to fall back on when GitHub refuses. */
const GITHUB_LAST_GOOD_SECONDS = 30 * 24 * 3600;

type Release = { tag_name: string; published_at: string | null; draft: boolean; assets: { name: string; download_count: number }[] };

function releaseDownloads(releases: Release[]): ReleaseDownloads[] {
  return releases
    .filter((r) => !r.draft)
    .map((r) => ({
      tag: r.tag_name,
      publishedAt: (r.published_at ?? "").slice(0, 10),
      dmg: r.assets.find((a) => a.name === "Matilde.dmg")?.download_count ?? 0,
      appcast: r.assets.find((a) => a.name === "appcast.xml")?.download_count ?? 0,
    }));
}

/** A readable reason for a refused GitHub request. */
export function githubError(status: number, hasToken: boolean): string {
  if (status === 403 || status === 429) {
    return hasToken
      ? `GitHub answered ${status}: rate limited, or GITHUB_TOKEN lacks read access to the repository`
      : `GitHub answered ${status}: rate limited, set GITHUB_TOKEN`;
  }
  if (status === 401) return hasToken ? "GitHub answered 401: GITHUB_TOKEN is invalid or expired" : "GitHub answered 401";
  return `GitHub answered ${status}`;
}

export async function githubDownloads(env: Env, fetcher: typeof fetch = fetch, cache?: Cache): Promise<Result<ReleaseDownloads[]>> {
  if (!/^[\w.-]+\/[\w.-]+$/.test(env.GITHUB_REPO)) return { ok: false, error: "invalid GITHUB_REPO" };
  const url = `https://api.github.com/repos/${env.GITHUB_REPO}/releases?per_page=100`;
  // Cache keys only; never fetched. The fresh copy lasts an hour, the last good one a month.
  const freshKey = url;
  const lastGoodKey = `${url}&matilde-cache=last-good`;
  const token = env.GITHUB_TOKEN?.trim();

  try {
    const cached = cache ? await cache.match(freshKey) : undefined;
    if (cached) return { ok: true, value: releaseDownloads((await cached.json()) as Release[]) };
  } catch {
    // A broken cache entry: fetch again.
  }

  let error: string;
  try {
    // Without a token GitHub allows 60 requests an hour per IP, shared with everything else on
    // Cloudflare's egress addresses; with one, 5,000 an hour for the token.
    const headers: Record<string, string> = { Accept: "application/vnd.github+json", "User-Agent": "matilde-stats", "X-GitHub-Api-Version": "2022-11-28" };
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetcher(url, { headers });
    if (res.ok) {
      const text = await res.text();
      const value = releaseDownloads(JSON.parse(text) as Release[]);
      if (cache) {
        const store = (seconds: number) => new Response(text, { headers: { "Content-Type": "application/json", "Cache-Control": `max-age=${seconds}`, Date: new Date().toUTCString() } });
        await Promise.all([cache.put(freshKey, store(GITHUB_CACHE_SECONDS)), cache.put(lastGoodKey, store(GITHUB_LAST_GOOD_SECONDS))]);
      }
      return { ok: true, value };
    }
    error = githubError(res.status, Boolean(token));
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }

  try {
    const lastGood = cache ? await cache.match(lastGoodKey) : undefined;
    if (lastGood) {
      const date = lastGood.headers.get("Date");
      const when = date && !Number.isNaN(Date.parse(date)) ? ` from ${new Date(date).toISOString().slice(0, 16).replace("T", " ")} UTC` : "";
      return { ok: true, value: releaseDownloads((await lastGood.json()) as Release[]), warning: `${error}. Showing the last good copy${when}` };
    }
  } catch {
    // Fall through to the error.
  }
  return { ok: false, error };
}

// MARK: Sync server

export async function syncStats(env: Env): Promise<Result<SyncStats>> {
  return attempt(async () => {
    if (!env.SYNC) throw new Error("the SYNC service binding is missing");
    return env.SYNC.stats();
  });
}

// MARK: day helpers

export const DAY_MS = 24 * 3600 * 1000;

export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** The last `days` UTC days, oldest first, ending today. */
export function lastDays(nowMs: number, days = DAYS): string[] {
  return Array.from({ length: days }, (_, i) => utcDay(nowMs - (days - 1 - i) * DAY_MS));
}

/** Values per day over `days`, zero where a day has none. */
export function series(values: DayValue[], days: string[]): number[] {
  const byDay = new Map<string, number>();
  for (const v of values) byDay.set(v.day, (byDay.get(v.day) ?? 0) + v.value);
  return days.map((d) => byDay.get(d) ?? 0);
}

/** Today, the last 7 days and the last 30 days of a daily series (last element = today). */
export function windows(values: number[]): { today: number; week: number; month: number } {
  const sum = (n: number) => values.slice(-n).reduce((a, b) => a + b, 0);
  return { today: values[values.length - 1] ?? 0, week: sum(7), month: sum(30) };
}
