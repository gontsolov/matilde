import { HttpError } from "../util";

export interface Limit {
  /** Already hashed; never a plain email or IP. */
  key: string;
  windowSeconds: number;
  max: number;
}

export class RateLimitError extends HttpError {
  constructor(
    retryAfter: number,
    /** Keys of the limits that were exceeded. */
    readonly exceeded: string[],
  ) {
    super(429, "rate_limited", "too many requests, try again later", { "Retry-After": String(retryAfter) });
  }
}

/**
 * Fixed-window counters in D1. Each call counts one hit against every limit
 * and throws 429 if any is exceeded.
 */
export async function enforceLimits(db: D1Database, limits: Limit[], nowMs = Date.now()): Promise<void> {
  const statements = limits.map((limit) => {
    const windowMs = limit.windowSeconds * 1000;
    const windowStart = Math.floor(nowMs / windowMs) * windowMs;
    return db
      .prepare(
        `INSERT INTO rate_counters (key, window_start, count, expires_at) VALUES (?1, ?2, 1, ?3)
         ON CONFLICT(key) DO UPDATE SET
           count = CASE WHEN rate_counters.window_start = excluded.window_start THEN rate_counters.count + 1 ELSE 1 END,
           window_start = excluded.window_start,
           expires_at = excluded.expires_at
         RETURNING count, window_start`,
      )
      .bind(limit.key, windowStart, windowStart + windowMs);
  });
  const results = await db.batch<{ count: number; window_start: number }>(statements);
  let retryAfter = 0;
  const exceeded: string[] = [];
  results.forEach((result, index) => {
    const row = result.results[0];
    const limit = limits[index]!;
    if (row && row.count > limit.max) {
      exceeded.push(limit.key);
      retryAfter = Math.max(retryAfter, Math.ceil((row.window_start + limit.windowSeconds * 1000 - nowMs) / 1000));
    }
  });
  if (exceeded.length) throw new RateLimitError(Math.max(1, retryAfter), exceeded);
}

/** /24 for IPv4, /48 for IPv6: a whole home or office network counts as one. */
export function ipPrefix(ip: string): string {
  if (ip.includes(":")) {
    const [head = "", tail] = ip.toLowerCase().split("::");
    const left = head ? head.split(":") : [];
    const right = tail ? tail.split(":") : [];
    const groups = tail === undefined ? left : [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
    return groups.slice(0, 3).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/48";
  }
  const parts = ip.split(".");
  return parts.length === 4 ? `${parts.slice(0, 3).join(".")}.0/24` : "unknown";
}
