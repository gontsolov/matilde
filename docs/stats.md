# Usage stats (stats.matilde.page)

A private dashboard of anonymous counts for the owner: website visits, downloads, update checks
(roughly, Macs in use), sync accounts and devices, stored notes and feedback. Counts only. There is
no weekly email; the page is the only place they show up. Roadmap: DIST-09.

## What is kept, and where

Nothing here can single out a person: no IP addresses, no account, device or user ids, no full user
agents, no content. Every number is a sum.

| Number | Source | What one count is |
| --- | --- | --- |
| Visits | Cloudflare Web Analytics for matilde.page (cookieless beacon), read via the GraphQL Analytics API | A visit as Cloudflare defines it: a page view that came from another site or was typed in |
| Download clicks | `matilde.page/download` in the `matilde-web` Worker (`apps/web/worker`), stored in Workers Analytics Engine dataset `matilde_web_events` | One GET of /download that isn't an obvious bot, link preview or script; then a 302 to the latest `Matilde.dmg` |
| GitHub downloads | GitHub's per-asset `download_count`, public API, cached for an hour | All-time downloads of `Matilde.dmg` and `appcast.xml` per release |
| Update checks per day | `matilde.page/appcast.xml` in `matilde-web`, same dataset | One GET of the feed, with only the Matilde version and macOS major version (from the user agent); then a 302 to the release's signed `appcast.xml` |
| Macs a day (estimate) | Derived on the page | The average update checks per day over the last 7 full days |
| Accounts, new accounts per day | Sync server D1 (`accounts.created_at`) | One account |
| Active 7 / 30 days | Sync server D1 (`sessions.last_seen_day`, day resolution) | An account with a signed-in device that refreshed its session in the window |
| Devices by platform | Sync server D1 (`sessions.platform`) | One signed-in device (Mac, iPhone, iPad) |
| Notes and drafts, encrypted records | `stats_totals` in D1, kept by the per-user Durable Objects | One live (non-deleted) record; "notes and drafts" are records of type draft |
| Feedback per day | `stats_daily` in D1, counted when a message is submitted | One submission, by kind (bug, idea, other) |

### Limits worth knowing

- **Download clicks aren't downloads.** A click can be abandoned, and someone may click twice. Direct
  links to GitHub (the README, the releases page) bypass /download; GitHub's numbers cover those.
- **GitHub's DMG count includes updates.** Sparkle downloads the same `Matilde.dmg` when it installs an
  update, so per-release DMG counts are new installs plus updates. GitHub counts are all-time per
  release, not per day.
- **Update checks are an estimate of Macs.** Sparkle checks about once a day while Matilde runs (and
  at launch when a day has passed), plus every Check for Updates. A Mac that stays closed isn't
  counted; one that checks manually several times counts more than once. Treat "Macs a day" as a
  rough figure.
- **Old installs use the old feed.** Versions up to 0.3.1 have
  `https://github.com/gontsolov/matilde/releases/latest/download/appcast.xml` built in and keep asking
  GitHub directly until they install an update; only then do they use `matilde.page/appcast.xml`. Their
  checks show up as the `appcast.xml` column in the GitHub table (all-time per release), not in the
  daily chart. The macOS column says "unknown" for versions that don't send it (0.3.1 and older,
  which only reach matilde.page if someone points them there).
- **Analytics Engine keeps three months.** The daily charts cover 30 days, so that's enough; there is
  no all-time total of /download clicks. At very high volume Analytics Engine samples; the page
  multiplies by `_sample_interval`, so totals stay right.
- **Web Analytics** misses visitors whose browser blocks its beacon.
- **Active accounts** come from session refreshes (about every 15 minutes while sync runs). Sessions
  unused for 90 days are deleted, which doesn't affect the 7- and 30-day windows. The daily chart of
  active accounts starts on the day the server change is deployed.
- **Record totals** are kept as deltas: after each push the account's Durable Object adds the change in
  its live record count to the totals, without saying which account it is. Accounts that existed
  before the change are added the next time one of their devices syncs (push or pull), so the totals
  catch up over the first day. A failed write is retried on the next sync. A deleted account takes its
  records back out.
- **Feedback** counts start with what's still in the `feedback` table (delivered messages are kept 30
  days), then count every stored submission. Rate-limited ones aren't counted, since they're never
  stored.
- **Preview versions** of the site (pull requests) write to the same dataset, so a reviewer clicking
  Download on a preview adds a click.

## How it's put together

- `apps/web/worker/index.ts` (matilde.page): `/download` and `/appcast.xml` add one Analytics Engine data
  point each (`blobs: [event, version, os]`) and redirect with `Cache-Control: no-store`. HEAD requests
  aren't counted. The Download buttons on the site link to `/download`.
- The Mac app's feed is `https://matilde.page/appcast.xml` (`apps/macos/Config/release.json`, from the
  release after 0.3.1) and its Sparkle user agent ends in `macOS/<major>`. The redirect hands Sparkle
  the signed file from GitHub byte for byte; the feed signature and the DMG's EdDSA signature are
  checked exactly as before (`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`).
- `server/` (sync server): migration `0004_stats.sql` adds `stats_totals` and `stats_daily`. The cron
  (every 15 minutes) writes today's snapshot (accounts, active, devices, records) into `stats_daily`.
  `StatsApi` (`server/src/stats/api.ts`) is a named Worker entrypoint with **no HTTP route**: it can only
  be called through a service binding from a Worker in the same Cloudflare account. It runs a few
  COUNT queries over the directory; no Durable Object is opened.
- `apps/stats/` (`matilde-stats`, stats.matilde.page): renders the page from the four sources. Each
  source can fail on its own; the page then says which one is missing. Every request must carry a
  valid Cloudflare Access JWT (`Cf-Access-Jwt-Assertion`): signed by the team's Access keys
  (`https://<team>/cdn-cgi/access/certs`), issuer `https://<team>`, audience = the application's AUD
  tag, unexpired, and an email in `ACCESS_ALLOWED_EMAILS`. Any missing setting means everyone gets
  403. No workers.dev or preview URLs.

### Deploys

- `matilde-web`: `.github/workflows/web.yml`, automatically on merge (now also runs `pnpm test` and
  checks both redirects after deploying).
- Sync server: `.github/workflows/server.yml`, staging automatically, production after the owner's
  approval. The stats page reads **production** (`service: "matilde-sync"`).
- `matilde-stats`: `.github/workflows/stats.yml`, automatically on merge, like the website: it only
  reads counts, writes nothing, and is private twice over. After deploying it checks that an
  anonymous request gets 302 (Access) or 403 (the Worker), never 200. Roll back with
  `pnpm exec wrangler rollback` in `apps/stats`.

## Owner setup

Do these once, after the pull request is merged and its three workflows have run. Run the
`wrangler` commands on the Mac, logged in with `pnpm exec wrangler login`. Each `secret put` asks for
the value at a prompt; type or paste it there, never into a chat or a file.

1. **Approve the production server deploy** (Actions → the Server run → Review deployments →
   production → Approve). Without it the Sync section says the entrypoint is missing.

2. **Turn on Web Analytics for matilde.page.** Cloudflare dashboard → **Analytics & Logs → Web
   Analytics → Add a site** → choose `matilde.page` from your zones → **Done** (automatic setup; no
   snippet needed for a domain on Cloudflare). Then find its **site tag**: open the site in Web
   Analytics; the address bar contains `siteTag~in=<site tag>`. If visits stay at zero a day later, the
   automatic beacon isn't being added to the Worker's pages: tell an agent to add the manual JS
   snippet from **Manage site** to `apps/web/src/layouts/Base.astro`.

3. **Create a read-only API token for the analytics.** dashboard → **My Profile → API Tokens →
   Create Token → Create Custom Token**:
   - Name: `matilde-stats analytics (read)`
   - Permissions: **Account → Account Analytics → Read**, nothing else
   - Account Resources: Include → your account
   - Create, then copy the token straight into the prompt of step 5.

4. **Cloudflare Access for stats.matilde.page.**
   1. dashboard → **Zero Trust**. The first time, pick a team name (your team domain becomes
      `<team>.cloudflareaccess.com`) and the **Free** plan.
   2. **Settings → Authentication → Login methods**: make sure **One-time PIN** is listed (it is by
      default).
   3. **Access → Applications → Add an application → Self-hosted.** Name `Matilde stats`, session
      duration 24 hours (or what you like). **Add public hostname**: subdomain `stats`, domain
      `matilde.page`, path empty.
   4. **Policy**: name `Owner`, action **Allow**, Include → **Emails** → your email address. Only
      one-time PIN as the login method (turn off any others offered for this app).
   5. Save. Open the application again → **Overview** (or Basic information) and copy the
      **Application Audience (AUD) Tag**.

5. **Secrets for the stats Worker** (from `apps/stats`):
   ```sh
   cd apps/stats
   pnpm exec wrangler secret put ACCESS_TEAM_DOMAIN      # <team>.cloudflareaccess.com
   pnpm exec wrangler secret put ACCESS_AUD              # the AUD tag from step 4.5
   pnpm exec wrangler secret put ACCESS_ALLOWED_EMAILS   # your email (comma-separate several)
   pnpm exec wrangler secret put CF_ACCOUNT_ID           # Workers & Pages → Account ID
   pnpm exec wrangler secret put CF_ANALYTICS_TOKEN      # the token from step 3
   pnpm exec wrangler secret put WEB_ANALYTICS_SITE_TAG  # the site tag from step 2 (optional)
   ```
   Secrets take effect at once; no redeploy needed.

6. **DNS and the custom domain.** Nothing to do: `wrangler deploy` creates `stats.matilde.page`'s DNS
   record and certificate (there must be no existing `stats` record). If the Stats deploy fails with a
   permission error, the `CLOUDFLARE_API_TOKEN` repository secret needs the same permissions as the
   website's (Workers Scripts Edit, Workers Routes Edit and DNS Edit on matilde.page).

7. **Check it.**
   ```sh
   curl -sI https://stats.matilde.page | head -1          # 302 to Access sign-in (never 200)
   curl -sI https://matilde.page/download | grep -i location
   curl -sI https://matilde.page/appcast.xml | grep -i location
   ```
   Then open **https://stats.matilde.page**: Access mails a six-digit code to your address, and the
   page loads. Download clicks show up within a minute or two; update checks start once Macs run the
   first release with the new feed address.

## Where to look

- **https://stats.matilde.page**: everything above, today / 7 days / 30 days and a 30-day chart each.
- Web Analytics in the Cloudflare dashboard: referrers, pages and countries for visits (the stats page
  shows only the daily count).
- Raw counts, if ever needed:
  ```sh
  cd server && pnpm exec wrangler d1 execute DB --remote --env production --command "SELECT * FROM stats_totals"
  ```
