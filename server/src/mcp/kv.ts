// A KV-namespace-compatible adapter over D1 for @cloudflare/workers-oauth-provider, which only uses
// get (text/json), put (with expirationTtl and metadata), delete and list (prefix, limit, cursor).
// Keeping OAuth state in the directory database means no extra binding to provision and the data
// stays in the EU D1 database. See docs/mcp.md, "Where it runs".

interface Row {
  key: string;
  value: string;
  metadata: string | null;
  expires_at: number | null;
}

export function d1Kv(db: D1Database, now: () => number = Date.now): KVNamespace {
  const live = "(expires_at IS NULL OR expires_at > ?)";
  const kv = {
    async get(key: string, options?: unknown) {
      const type = typeof options === "string" ? options : ((options as { type?: string } | undefined)?.type ?? "text");
      const row = await db.prepare(`SELECT value FROM mcp_oauth_kv WHERE key = ? AND ${live}`).bind(key, now()).first<{ value: string }>();
      if (!row) return null;
      if (type === "json") return JSON.parse(row.value);
      if (type !== "text") throw new Error(`d1Kv: unsupported type ${type}`);
      return row.value;
    },
    async put(key: string, value: string, options?: { expirationTtl?: number; expiration?: number; metadata?: unknown }) {
      if (typeof value !== "string") throw new Error("d1Kv: only string values");
      const expires = options?.expirationTtl ? now() + options.expirationTtl * 1000 : options?.expiration ? options.expiration * 1000 : null;
      const metadata = options?.metadata === undefined ? null : JSON.stringify(options.metadata);
      await db
        .prepare(
          `INSERT INTO mcp_oauth_kv (key, value, metadata, expires_at) VALUES (?, ?, ?, ?)
           ON CONFLICT(key) DO UPDATE SET value = excluded.value, metadata = excluded.metadata, expires_at = excluded.expires_at`,
        )
        .bind(key, value, metadata, expires)
        .run();
    },
    async delete(key: string) {
      await db.prepare("DELETE FROM mcp_oauth_kv WHERE key = ?").bind(key).run();
    },
    async list(options?: { prefix?: string; limit?: number; cursor?: string }) {
      const prefix = options?.prefix ?? "";
      const limit = Math.max(1, Math.min(options?.limit ?? 1000, 1000));
      const rows = await db
        .prepare(`SELECT key, metadata, expires_at FROM mcp_oauth_kv WHERE substr(key, 1, ?) = ? AND key > ? AND ${live} ORDER BY key LIMIT ?`)
        .bind(prefix.length, prefix, options?.cursor ?? "", now(), limit + 1)
        .all<Omit<Row, "value">>();
      const page = rows.results.slice(0, limit);
      const complete = rows.results.length <= limit;
      return {
        keys: page.map((r) => ({
          name: r.key,
          ...(r.expires_at ? { expiration: Math.floor(r.expires_at / 1000) } : {}),
          ...(r.metadata ? { metadata: JSON.parse(r.metadata) } : {}),
        })),
        list_complete: complete,
        ...(complete ? {} : { cursor: page[page.length - 1]!.key }),
        cacheStatus: null,
      };
    },
  };
  return kv as unknown as KVNamespace;
}

/** Daily cleanup of expired OAuth records. */
export async function purgeExpiredKv(db: D1Database, nowMs = Date.now()): Promise<void> {
  await db.prepare("DELETE FROM mcp_oauth_kv WHERE expires_at IS NOT NULL AND expires_at <= ?").bind(nowMs).run();
}
