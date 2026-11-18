-- Email one-time codes, sessions and sign-in rate limits (SYNC-05).

-- One active code per address. email_key = HMAC(pepper, address); code_hash =
-- HMAC(pepper, address | code). Neither the code nor the address is stored here.
CREATE TABLE email_codes (
  email_key TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

-- One session per device. The refresh token is stored only as SHA-256.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  platform TEXT NOT NULL,
  name_ct TEXT,                        -- device name encrypted by the client with AK (base64), opaque here
  refresh_hash TEXT NOT NULL,
  prev_refresh_hash TEXT,              -- previous token, accepted only during a short retry grace
  rotated_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen_day TEXT NOT NULL,         -- YYYY-MM-DD, day resolution on purpose
  expires_at INTEGER NOT NULL          -- refresh expiry, slides on every use
);
CREATE INDEX sessions_account ON sessions(account_id);
CREATE UNIQUE INDEX sessions_device ON sessions(account_id, device_id);

-- Fixed-window counters for sign-in rate limits. Keys are hashed.
CREATE TABLE rate_counters (
  key TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
