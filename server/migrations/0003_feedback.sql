-- In-app feedback (FEEDBACK). Each message becomes an issue in the owner's Linear
-- workspace. A row is written before delivery so nothing is lost if Linear is not
-- configured or fails; the daily cron retries pending rows. Once delivered, the
-- payload is cleared (the text then lives only in Linear) and the row is deleted
-- after 30 days. Holds only what the user typed or opted into: no account id,
-- no account email, no IP.

CREATE TABLE feedback (
  id TEXT PRIMARY KEY,                 -- random UUID
  created_at INTEGER NOT NULL,         -- ms since epoch
  updated_at INTEGER NOT NULL,
  kind TEXT NOT NULL,                  -- 'bug' | 'idea' | 'other'
  payload TEXT,                        -- JSON {message, replyEmail, diagnostics, signedIn}; NULL once sent
  status TEXT NOT NULL,                -- 'pending' | 'sent' | 'failed' (gave up after too many attempts)
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,                     -- short code only (e.g. 'not_configured', 'http_401'), never content
  linear_issue TEXT                    -- Linear identifier (e.g. 'MAT-12') once sent
);
CREATE INDEX feedback_status ON feedback(status, created_at);
