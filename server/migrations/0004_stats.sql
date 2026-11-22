-- Anonymous usage counts for the owner's stats page (stats.matilde.page). Aggregates only:
-- no account ids, device ids, IPs or content, and nothing that could single out a person.

-- Running totals kept up to date by the per-user Durable Objects as records come and go:
--   records_live  encrypted records that are not tombstones (every type)
--   drafts_live   live records of type 1 (draft): one per note or alternate draft
CREATE TABLE stats_totals (
  metric TEXT PRIMARY KEY,
  value INTEGER NOT NULL
);

-- One value per UTC day and metric. Feedback submissions are counted as they arrive
-- ('feedback:bug', 'feedback:idea', 'feedback:other'); the cron writes a snapshot of the
-- totals (accounts, active accounts, devices by platform, records) every run, so a past
-- day keeps the last value of that day.
CREATE TABLE stats_daily (
  day TEXT NOT NULL,                   -- YYYY-MM-DD (UTC)
  metric TEXT NOT NULL,
  value INTEGER NOT NULL,
  PRIMARY KEY (day, metric)
);

-- Feedback that arrived before this migration (delivered rows are kept for 30 days).
INSERT INTO stats_daily (day, metric, value)
  SELECT strftime('%Y-%m-%d', created_at / 1000, 'unixepoch'), 'feedback:' || kind, COUNT(*)
  FROM feedback GROUP BY 1, 2;
