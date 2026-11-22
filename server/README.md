# Matilde sync server

The server side of Matilde's end-to-end encrypted cloud sync: one TypeScript Cloudflare Worker.

- **Durable Object `UserSync`**, one per user (SQLite, EU): the sync authority. Records, sequence numbers, compare-and-swap, blob index, WebSocket nudges.
- **D1 "directory"** (EU): accounts, sign-in identities, email codes, sessions, wrapped key slots, rate-limit counters. No writing.
- **Feedback** (`POST /v1/feedback`): in-app feedback becomes an issue in the owner's Linear workspace. It holds only what the user typed, an optional reply email and opt-in diagnostics; it waits in D1 only until Linear has it. Setup: [docs/feedback.md](../docs/feedback.md).
- **R2** (EU): encrypted blobs and ciphertext over 256 KB, under `u/<userId>/`.
- **Usage stats** (`StatsApi`, `src/stats/`): anonymous aggregate counts for the owner's stats page (accounts, active accounts, devices by platform, live record totals, feedback per day). A named entrypoint with no HTTP route, reachable only through the `matilde-stats` Worker's service binding. See [docs/stats.md](../docs/stats.md).

The server only ever stores ciphertext plus a small envelope (id, type, HLC, device, deleted flag, key id, size, blob id, sequence). The API is specified in [PROTOCOL.md](PROTOCOL.md); the Swift client (SYNC-07) follows it.

```
src/index.ts            entry: fetch + cron (every 15 minutes)
src/app.ts              Hono router, logging, error mapping, minimum app build
src/auth/               email codes, mailers, rate limits, sessions/devices, tokens, account + key routes
src/sync/UserSync.ts    the per-user Durable Object
src/sync/routes.ts      push / pull / ws / blobs
src/feedback/           POST /v1/feedback: validation, Linear issue, D1 queue + retry
src/stats/              anonymous usage counters + the RPC-only StatsApi entrypoint
migrations/             D1 migrations (directory)
test/                   vitest in the Workers runtime (@cloudflare/vitest-plugin)
```

## Local development

Needs Node.js 22.12 or newer and pnpm (`corepack enable` once installs the version pinned in the root `package.json`). The server is part of the repo's pnpm workspace with one root `pnpm-lock.yaml`. Everything runs locally in `workerd` through Miniflare (no Cloudflare account needed).

```sh
cd server
pnpm install
cp .dev.vars.example .dev.vars
pnpm run --silent gen-signing-key     # paste the output as TOKEN_SIGNING_KEY in .dev.vars
pnpm run migrate:local
pnpm run dev                          # http://localhost:8787
```

Locally `MAIL_PROVIDER` is `console`: sign-in codes are printed in the `wrangler dev` output instead of being mailed.

```sh
curl -X POST localhost:8787/v1/auth/email/start -H 'content-type: application/json' -d '{"email":"me@example.com"}'
# read the code in the dev console, then:
curl -X POST localhost:8787/v1/auth/email/verify -H 'content-type: application/json' \
  -d '{"email":"me@example.com","code":"123456","deviceId":"'$(uuidgen | tr A-Z a-z)'","platform":"macos"}'
```

Local `workerd` doesn't implement Durable Object jurisdictions, so `DO_JURISDICTION` is empty at the top level of `wrangler.jsonc`; staging and production set `"eu"`.

## Tests

```sh
pnpm run typecheck
pnpm test
```

The tests run inside the Workers runtime with real D1, R2 and Durable Object implementations (Miniflare), on Linux or macOS. They cover sign-in codes (hashing, expiry, attempts, rate limits), token rotation and reuse detection, devices and revocation, push/pull/cursor, LWW and body conflicts, tombstones, large records in R2, blobs and garbage collection, WebSocket nudges, per-user isolation, account deletion, that the server syncs client-encrypted data it can't read, and feedback (validation, rate limits, the Linear request with a mocked `fetch`, queueing and retries). Test secrets are generated per run in `vitest.config.ts`.

## Configuration

`wrangler.jsonc` has three environments: the top level (local dev and tests), `staging` and `production`. Each deployed environment has its own Worker, D1 database, R2 bucket and Durable Object namespace.

**Domain:** `matilde.page`. Production is `https://sync.matilde.page`, staging `https://sync-staging.matilde.page` (Workers custom domains: `wrangler deploy` creates their DNS records and certificates), and sign-in mail comes from `Matilde <sign-in@matilde.page>`. The domain was set with `pnpm run set-domain matilde.page`, which replaced the `matilde.example` placeholder in `wrangler.jsonc`.

**Mail:** staging and production use **Cloudflare Email Service** (Email Sending): `MAIL_PROVIDER: "cloudflare"` and a `send_email` binding `EMAIL` per environment, with no API key. The binding sets no `destination_address` or `allowed_destination_addresses` (either would limit who can get a code); `allowed_sender_addresses` pins it to `sign-in@matilde.page`. Per Cloudflare's docs (checked 2026-11-18):

- Email Sending is in **public beta** (since 2026-04-16); there is no waitlist, but it needs the **Workers Paid** plan.
- An unrestricted binding can mail **any recipient once the sender domain is onboarded** for Email Sending. Before that it can only reach verified destination addresses of the account, so onboarding `matilde.page` is required before sign-in works for real users.
- Workers Paid includes 3,000 mails a month, then $0.35 per 1,000. New accounts start with a conservative daily sending quota that grows with reputation; sends over it fail (for example `E_RATE_LIMIT_EXCEEDED`; the API answers `502 mail_failed`), possibly well below `GLOBAL_DAILY_CODE_CAP` at first. The limit-increase form is linked from Cloudflare's Email Service "Limits" page.
- Failures are logged as `mail_failed` with only the Cloudflare error code, e.g. `cloudflare email failed: E_SENDER_DOMAIN_NOT_AVAILABLE` (domain not onboarded) or `E_SENDER_NOT_VERIFIED` (sender not allowed).
- `E_RECIPIENT_NOT_ALLOWED` means either a destination restriction on the binding (the tests make sure staging and production have none) or that `matilde.page` is **not onboarded for Email Sending**: then the binding still works, but only to the account's verified destination addresses. **Email Routing is a separate product** and onboarding it does not enable sending. Routing puts MX/SPF on the root domain and DKIM on `cf2024-1._domainkey`; Sending adds records on `cf-bounce` (`dig MX cf-bounce.matilde.page` must return `route1/2/3.mx.cloudflare.net`) and `cf-bounce._domainkey`. If those are missing, onboard the domain under **Email Sending** (checklist step 4). Until then, a sign-in can be tested by adding the address as a verified destination (Email Routing → Destination addresses). No redeploy is needed either way.

| Logged code | Meaning | Fix |
| --- | --- | --- |
| `E_RECIPIENT_NOT_ALLOWED` | Domain not onboarded for Email Sending (only verified destinations allowed), or a destination restriction on the binding | Onboard under Email Sending; check `cf-bounce` DNS |
| `E_SENDER_DOMAIN_NOT_AVAILABLE` / `E_SENDER_DOMAIN_NOT_CONFIGURED` | Sender domain not onboarded or not active for sending | Onboard under Email Sending |
| `E_EMAIL_SENDING_NOT_READY` | Onboarding still finishing | Retry in a few minutes |
| `E_SENDER_NOT_VERIFIED` | `MAIL_FROM` not in `allowed_sender_addresses` | Fix `wrangler.jsonc`, redeploy |
| `E_RECIPIENT_PLAN_RESTRICTED` | Plan only allows verified destinations | Workers Paid |
| `E_RATE_LIMIT_EXCEEDED` / `E_DAILY_LIMIT_EXCEEDED` | New-account quota | Wait, or the Limits page's increase form |

**Fallback, Resend:** the Resend adapter stays in the code but not in the config. To switch an environment: set its `MAIL_PROVIDER` to `"resend"`, `wrangler secret put RESEND_API_KEY --env <env>`, verify `matilde.page` in Resend (EU region) with the DNS records it shows, and redeploy. The `send_email` binding can stay.

Vars (in `wrangler.jsonc`, not secret):

| Var | Meaning |
| --- | --- |
| `ENVIRONMENT` | `development`, `staging` or `production` |
| `MAIL_PROVIDER` | `cloudflare` (Email Service binding `EMAIL`; staging and production), `resend` (fallback), or `console` (local only) |
| `MAIL_FROM` | Sender: `Matilde <sign-in@matilde.page>` |
| `DO_JURISDICTION` | `eu` when deployed |
| `MIN_CLIENT_BUILD` | Lowest `X-Matilde-Build` accepted (`0` = off); older apps get `426` |
| `GLOBAL_DAILY_CODE_CAP` | Sign-in codes per day across all users before refusing more |
| `FEEDBACK_PER_IP_HOUR` | Feedback submissions per network (IPv4 /24) per hour (default 5) |
| `GLOBAL_DAILY_FEEDBACK_CAP` | Feedback submissions per day across everyone (200 production, 50 staging) |
| `LINEAR_TEAM_ID` | Linear team the issues go to (empty: feedback is only queued, `503 feedback_not_configured`) |
| `LINEAR_LABEL_BUG`, `LINEAR_LABEL_IDEA`, `LINEAR_LABEL_OTHER` | Label ids per kind; empty means no label |
| `LINEAR_LABEL_FEEDBACK` | Optional label added to every feedback issue |
| `LINEAR_PROJECT_ID`, `LINEAR_STATE_ID` | Optional project and workflow state (Triage). If Linear rejects them, the issue is created without them and `linear_placement_rejected` is logged |
| `MCP_ENABLED` | `"1"` serves the MCP server for AI tools on `MCP_ORIGIN` ([docs/mcp.md](../docs/mcp.md)); `"1"` on staging, `"0"` on production until switched on |
| `MCP_ORIGIN` | The MCP host: `https://mcp.matilde.page`, `https://mcp-staging.matilde.page`. Requests for it go to `src/mcp/`; everything else is the sync API |

### Secrets

Never committed. Set each one per environment (`--env staging` and `--env production`):

| Secret | Required | How to create |
| --- | --- | --- |
| `TOKEN_SIGNING_KEY` | yes | `pnpm run --silent gen-signing-key \| pnpm exec wrangler secret put TOKEN_SIGNING_KEY --env production` (Ed25519 private JWK with a `kid`; signs access tokens) |
| `CODE_PEPPER` | yes | `openssl rand -base64 32 \| pnpm exec wrangler secret put CODE_PEPPER --env production` (keys the hashes of emails, codes and IP prefixes) |
| `RESEND_API_KEY` | only for the Resend fallback (`MAIL_PROVIDER: "resend"`); not needed by default | from the Resend dashboard (sending access, restricted to the domain) |
| `LINEAR_API_KEY` | for feedback (without it feedback waits in D1) | Linear → Settings → Security & access → Personal API keys, limited to the team; `pnpm exec wrangler secret put LINEAR_API_KEY --env production`. Set on both environments (2026-11). See [docs/feedback.md](../docs/feedback.md) |
| `TOKEN_VERIFY_KEYS` | only during a key rotation | JSON array of old public JWKs, see below |

Use different values for staging and production. Changing `CODE_PEPPER` only invalidates codes in flight and resets rate-limit counters.

**Rotating the signing key:** keep the old key accepted for 15 minutes while new tokens use the new one.

```sh
# 1. public half of the current key (from wherever you kept it, or generate a fresh pair and skip this)
node scripts/gen-signing-key.mjs --public < old-key.json   # → {"kty":"OKP",...,"kid":"…"}
# 2. accept it, then switch
echo '[<public JWK from step 1>]' | pnpm exec wrangler secret put TOKEN_VERIFY_KEYS --env production
pnpm run --silent gen-signing-key | pnpm exec wrangler secret put TOKEN_SIGNING_KEY --env production
# 3. after 15 minutes
pnpm exec wrangler secret delete TOKEN_VERIFY_KEYS --env production
```

If the old private key wasn't kept, just replace `TOKEN_SIGNING_KEY`: every device then refreshes once (refresh tokens don't depend on the signing key).

## Owner setup checklist (before the first deploy)

1. **Cloudflare account on Workers Paid** ($5/month, Workers & Pages → Plans). The limits and included usage in the plan assume it.
2. **Spending and usage alerts:** in the dashboard's Notifications, add usage-based billing alerts for Workers, Durable Objects, D1 and R2 (and a billing budget alert if offered for the account). Once deployed, add a Workers Observability alert on the error rate and on `global_code_cap_reached` log events (the daily cap on sign-in mail was hit).
3. **Domain on Cloudflare DNS:** `matilde.page` must be an active zone in the same Cloudflare account (Cloudflare Registrar, or the existing registrar's nameservers pointed to Cloudflare). `sync` and `sync-staging` must have no existing DNS records; `wrangler deploy` creates them. The config already uses the domain.
4. **Email sending (Cloudflare Email Service):** Dashboard → **Compute → Email Service → Email Sending → Onboard Domain** → pick `matilde.page` → **Done**. Cloudflare adds and locks its records on the `cf-bounce` subdomain: three MX (`route1/2/3.mx.cloudflare.net`, bounces), SPF `TXT cf-bounce "v=spf1 include:_spf.mx.cloudflare.net ~all"` and DKIM `TXT cf-bounce._domainkey`. It also adds `TXT _dmarc "v=DMARC1; p=reject;"` **only if the domain has no DMARC record yet**. Email Sending → Settings → DNS records should then list all of them (Locked or Unlocked both mean configured). Nothing is configured on the Worker side beyond the committed binding.
5. **Create the resources in the EU** (logged in with `pnpm exec wrangler login`). R2 must be enabled for the account first (Dashboard → **R2 Object Storage** → **Purchase**/**Get started**); otherwise `r2 bucket create` fails with error 10042. If `d1 create` offers to add the binding to the config, answer no (`git checkout -- wrangler.jsonc` undoes a yes).
   ```sh
   pnpm exec wrangler d1 create matilde-directory-staging --jurisdiction eu
   pnpm exec wrangler d1 create matilde-directory --jurisdiction eu
   pnpm exec wrangler r2 bucket create matilde-blobs-staging --jurisdiction eu
   pnpm exec wrangler r2 bucket create matilde-blobs --jurisdiction eu
   ```
   The two D1 `database_id`s are already in `wrangler.jsonc` (both databases created in `eu` on 2026-11-18); a recreated database needs its new id there. The R2 jurisdiction can't be changed later. Durable Objects need no setup; the Worker pins them to `eu`.
6. **Secrets:** `TOKEN_SIGNING_KEY` and `CODE_PEPPER` for both environments (table above). Mail needs no secret.
7. **Migrate and deploy staging, then production:**
   ```sh
   pnpm run migrate:staging && pnpm run deploy:staging
   curl https://sync-staging.matilde.page/v1/health
   pnpm run migrate:production && pnpm run deploy:production
   curl https://sync.matilde.page/v1/health
   ```
8. **GitHub (deploy workflow):**
   - Create a Cloudflare API token (My Profile → API Tokens → Create Token → "Edit Cloudflare Workers" template), limited to this account and the domain's zone, and add **Account → D1 → Edit**. The template already has Workers Scripts (includes Durable Objects), Workers R2 Storage, Workers Routes and Account Settings read. If deploying the custom domain reports a permission error, add **Zone → DNS → Edit**.
   - Repository → Settings → Secrets and variables → Actions: add `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` (Dashboard → Workers & Pages → Account ID) as **repository** secrets, so both the staging and the production job can read them. (Done 2026-11-18.)
   - Repository → Settings → Environments → `production`: required reviewer = the owner, deployment branches = `main` only. (Done 2026-11-18.) The `staging` environment is created automatically by the first run and needs no protection.

## MCP server for AI tools

The same Worker also serves `mcp.matilde.page` (staging `mcp-staging.matilde.page`): an opt-in remote MCP server with OAuth 2.1 that lets a person connect claude.ai, ChatGPT, Cursor and similar tools to their notes. Design, security model, owner setup and how to connect each tool: [docs/mcp.md](../docs/mcp.md). It needs no new Cloudflare resources (OAuth state lives in D1, table `mcp_oauth_kv`); the custom domain is created by `wrangler deploy`. After editing `src/mcp/web/connect.js` run `pnpm run gen:mcp-assets`.

## Deploying

Deploys run from GitHub Actions (`.github/workflows/server.yml`):

- **Pull requests** touching `server/**`: `pnpm install`, `pnpm run typecheck`, `pnpm test`. No deploy.
- **Push to `main`** touching `server/**` (or **Run workflow** on `main` in the Actions tab): the same checks, then
  1. **staging**: `pnpm run migrate:staging` (D1 migrations, before the Worker), `pnpm run deploy:staging`, then `scripts/smoke-health.sh`, which fails the job unless `https://sync-staging.matilde.page/v1/health` returns 200 with `"ok":true`;
  2. **production**: waits for the owner's approval (Actions → the run → **Review deployments** → `production` → Approve), then the same three steps against `https://sync.matilde.page`.

Deploys never overlap: each environment has its own concurrency group and a running deploy is never cancelled. If several runs pile up, only the newest waiting one is kept, so approve the latest run. Rejecting (or not approving) the production step leaves production on its previous version; staging already has the new one.

Migrations run before the new Worker is live, so every migration must work with the Worker version that is still running (additive changes only; see Operations).

**Manual fallback** (e.g. Actions unavailable), from `server/` and logged in with `pnpm exec wrangler login`:

```sh
pnpm run check
pnpm run migrate:staging && pnpm run deploy:staging
bash scripts/smoke-health.sh https://sync-staging.matilde.page/v1/health
pnpm run migrate:production && pnpm run deploy:production
bash scripts/smoke-health.sh https://sync.matilde.page/v1/health
```

Secrets (`wrangler secret put`) are not part of the workflow; set them by hand as described under Secrets.

## Operations

- **Logs:** Workers Logs (observability is on). Each request logs method, route pattern, status, duration and error code; never bodies, tokens, codes, emails or IPs.
- **Cron** every 15 minutes: writes today's stats snapshot into `stats_daily` (docs/stats.md) and retries queued feedback (rows older than 5 minutes, 25 per run, `failed` after 10 attempts; sent rows are dropped after 30 days). The 03:15 UTC run also deletes expired codes, rate counters and sessions.
- **Feedback log events:** `feedback_queued` (Linear unreachable or not configured; with the reason, never the text), `feedback_rate_limited`, `global_feedback_cap_reached` (worth an Observability alert, like `global_code_cap_reached`) and `linear_placement_rejected` (project or state id wrong; issue created without them). Unsent feedback:
  ```sh
  pnpm exec wrangler d1 execute DB --remote --env production --command "SELECT id, created_at, status, attempts, last_error FROM feedback WHERE status != 'sent'"
  ```
- **Backups:** Durable Object point-in-time recovery (30 days) and D1 Time Travel (30 days); everything is ciphertext.
- **Schema changes:** D1 through `migrations/` (`wrangler d1 migrations create DB <name>`); the Durable Object migrates itself on start (`schema_version` in its `meta` table), additive only. Keep every change compatible with the previous app version.
