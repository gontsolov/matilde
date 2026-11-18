-- Account directory (D1, EU jurisdiction). Holds no writing: content lives
-- encrypted in the per-user Durable Object and R2.

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,                 -- random UUID, never derived from the email
  created_at INTEGER NOT NULL,         -- ms since epoch
  key_id INTEGER,                      -- current account-key epoch (SYNC-06), NULL until the first device sets it
  key_check TEXT                       -- base64 HMAC(AK, "check"), lets a device confirm it unwrapped the right key
);

-- Sign-in identities. provider = 'email' (subject = normalised address) now;
-- 'apple' (subject = Apple `sub`) is the seam for Sign in with Apple later.
CREATE TABLE identities (
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  email TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (provider, subject)
);
CREATE INDEX identities_account ON identities(account_id);

-- Wrapped copies of the account key (SYNC-06). Opaque to the server.
CREATE TABLE key_slots (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  slot_id TEXT NOT NULL,
  kind TEXT NOT NULL,                  -- 'recovery' | 'passphrase' | future kinds
  key_id INTEGER NOT NULL,
  params TEXT,                         -- JSON (e.g. Argon2id salt/params), opaque
  wrapped_key TEXT NOT NULL,           -- base64
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, slot_id)
);
