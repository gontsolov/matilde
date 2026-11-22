-- Matilde for AI tools (AI-18, docs/mcp.md). Connections an account owner made from an AI tool
-- (claude.ai, ChatGPT, Cursor, …) through the MCP server. No writing is stored here.

-- One row per connection. wrapped_ring is the account key ring sealed with the grant secret,
-- which only the tool's OAuth token carries; this table alone can't decrypt anything.
CREATE TABLE mcp_grants (
  id TEXT PRIMARY KEY,                 -- random UUID chosen by the consent page (in the wrap's AAD)
  user_id TEXT NOT NULL,               -- account id, or a random id for feedback-only connections
  oauth_grant_id TEXT,                 -- the OAuth library's grant id, for revocation
  client_id TEXT NOT NULL,
  client_name TEXT NOT NULL,           -- as shown on the consent screen (self-asserted unless verified)
  client_domain TEXT,                  -- verified domain of a CIMD client, else NULL
  redirect_host TEXT NOT NULL,
  scopes TEXT NOT NULL,                -- space-separated
  wrapped_ring BLOB,                   -- NULL for feedback-only connections and once revoked
  created_at INTEGER NOT NULL,         -- ms since epoch
  expires_at INTEGER NOT NULL,
  last_used_day TEXT,                  -- YYYY-MM-DD, day resolution on purpose
  revoked_at INTEGER
);
CREATE INDEX mcp_grants_user ON mcp_grants(user_id, created_at);

-- What a connection did: time, tool name and an outcome code. Never arguments or content.
CREATE TABLE mcp_audit (
  grant_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  tool TEXT NOT NULL,
  outcome TEXT NOT NULL                -- 'ok' or a short error code
);
CREATE INDEX mcp_audit_grant ON mcp_audit(grant_id, at);
CREATE INDEX mcp_audit_at ON mcp_audit(at);

-- Short-lived logins from the consent page's email-code step (15 minutes, single use).
CREATE TABLE mcp_logins (
  token_hash TEXT PRIMARY KEY,         -- SHA-256 of the random login token
  user_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

-- Storage for @cloudflare/workers-oauth-provider (clients, grants, token hashes), through a
-- KV-compatible adapter (src/mcp/kv.ts). Values are the library's own records; token-bound props
-- are encrypted by the library with a key derived from the token.
CREATE TABLE mcp_oauth_kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  metadata TEXT,
  expires_at INTEGER                   -- ms since epoch, NULL = no expiry
);
CREATE INDEX mcp_oauth_kv_expiry ON mcp_oauth_kv(expires_at) WHERE expires_at IS NOT NULL;
