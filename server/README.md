# Matilde sync server

The server side of Matilde's end-to-end encrypted cloud sync: one TypeScript Cloudflare Worker.

- **Durable Object `UserSync`**, one per user (SQLite, EU): the sync authority. Records, sequence numbers, compare-and-swap, blob index, WebSocket nudges.
- **D1 "directory"** (EU): accounts, sign-in identities, email codes, sessions, wrapped key slots, rate-limit counters. No writing.
- **R2** (EU): encrypted blobs and ciphertext over 256 KB, under `u/<userId>/`.

The server only ever stores ciphertext plus a small envelope (id, type, HLC, device, deleted flag, key id, size, blob id, sequence). The API is specified in [PROTOCOL.md](PROTOCOL.md); the Swift client (SYNC-07) follows it.

```
src/index.ts            entry: fetch + daily cron
src/app.ts              Hono router, logging, error mapping, minimum app build
src/auth/               email codes, mailers, rate limits, sessions/devices, tokens, account + key routes
src/sync/UserSync.ts    the per-user Durable Object
src/sync/routes.ts      push / pull / ws / blobs
migrations/             D1 migrations (directory)
test/                   vitest in the Workers runtime (@cloudflare/vitest-plugin)
```

## Local development

Needs Node.js 22 or newer. Everything runs locally in `workerd` through Miniflare (no Cloudflare account needed).

```sh
cd server
npm ci
cp .dev.vars.example .dev.vars
npm run --silent gen-signing-key     # paste the output as TOKEN_SIGNING_KEY in .dev.vars
npm run migrate:local
npm run dev                          # http://localhost:8787
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
npm run typecheck
npm test
```

The tests run inside the Workers runtime with real D1, R2 and Durable Object implementations (Miniflare), on Linux or macOS. They cover sign-in codes (hashing, expiry, attempts, rate limits), token rotation and reuse detection, devices and revocation, push/pull/cursor, LWW and body conflicts, tombstones, large records in R2, blobs and garbage collection, WebSocket nudges, per-user isolation, account deletion, and that the server syncs client-encrypted data it can't read. Test secrets are generated per run in `vitest.config.ts`.

## Configuration

`wrangler.jsonc` has three environments: the top level (local dev and tests), `staging` and `production`. Each deployed environment has its own Worker, D1 database, R2 bucket and Durable Object namespace.

**Domain:** `matilde.page`. Production is `https://sync.matilde.page`, staging `https://sync-staging.matilde.page` (Workers custom domains: `wrangler deploy` creates their DNS records and certificates), and sign-in mail comes from `Matilde <sign-in@matilde.page>`. The domain was set with `npm run set-domain -- matilde.page`, which replaced the `matilde.example` placeholder in `wrangler.jsonc`.

**Mail:** staging and production use `MAIL_PROVIDER: "resend"`. To switch to Cloudflare Email Service, set `MAIL_PROVIDER` to `"cloudflare"` in that environment and uncomment its `send_email` binding.

Vars (in `wrangler.jsonc`, not secret):

| Var | Meaning |
| --- | --- |
| `ENVIRONMENT` | `development`, `staging` or `production` |
| `MAIL_PROVIDER` | `cloudflare` (Email Service binding `EMAIL`), `resend`, or `console` (local only) |
| `MAIL_FROM` | Sender: `Matilde <sign-in@matilde.page>` |
| `DO_JURISDICTION` | `eu` when deployed |
| `MIN_CLIENT_BUILD` | Lowest `X-Matilde-Build` accepted (`0` = off); older apps get `426` |
| `GLOBAL_DAILY_CODE_CAP` | Sign-in codes per day across all users before refusing more |

### Secrets

Never committed. Set each one per environment (`--env staging` and `--env production`):

| Secret | Required | How to create |
| --- | --- | --- |
| `TOKEN_SIGNING_KEY` | yes | `npm run --silent gen-signing-key \| npx wrangler secret put TOKEN_SIGNING_KEY --env production` (Ed25519 private JWK with a `kid`; signs access tokens) |
| `CODE_PEPPER` | yes | `openssl rand -base64 32 \| npx wrangler secret put CODE_PEPPER --env production` (keys the hashes of emails, codes and IP prefixes) |
| `RESEND_API_KEY` | only if `MAIL_PROVIDER` is `resend` | from the Resend dashboard (sending access, restricted to the domain) |
| `TOKEN_VERIFY_KEYS` | only during a key rotation | JSON array of old public JWKs, see below |

Use different values for staging and production. Changing `CODE_PEPPER` only invalidates codes in flight and resets rate-limit counters.

**Rotating the signing key:** keep the old key accepted for 15 minutes while new tokens use the new one.

```sh
# 1. public half of the current key (from wherever you kept it, or generate a fresh pair and skip this)
node scripts/gen-signing-key.mjs --public < old-key.json   # → {"kty":"OKP",...,"kid":"…"}
# 2. accept it, then switch
echo '[<public JWK from step 1>]' | npx wrangler secret put TOKEN_VERIFY_KEYS --env production
npm run --silent gen-signing-key | npx wrangler secret put TOKEN_SIGNING_KEY --env production
# 3. after 15 minutes
npx wrangler secret delete TOKEN_VERIFY_KEYS --env production
```

If the old private key wasn't kept, just replace `TOKEN_SIGNING_KEY`: every device then refreshes once (refresh tokens don't depend on the signing key).

## Owner setup checklist (before the first deploy)

1. **Cloudflare account on Workers Paid** ($5/month, Workers & Pages → Plans). The limits and included usage in the plan assume it.
2. **Spending and usage alerts:** in the dashboard's Notifications, add usage-based billing alerts for Workers, Durable Objects, D1 and R2 (and a billing budget alert if offered for the account). Once deployed, add a Workers Observability alert on the error rate and on `global_code_cap_reached` log events (the daily cap on sign-in mail was hit).
3. **Domain on Cloudflare DNS:** `matilde.page` must be an active zone in the same Cloudflare account (Cloudflare Registrar, or the existing registrar's nameservers pointed to Cloudflare). `sync` and `sync-staging` must have no existing DNS records; `wrangler deploy` creates them. The config already uses the domain.
4. **Email sending:**
   - *Resend (configured):* create an account, add `matilde.page` in the EU region (eu-west-1), add the DNS records it shows (DKIM `resend._domainkey`, SPF and bounce MX on `send`), verify, then create an API key with sending access restricted to the domain and set it as the `RESEND_API_KEY` secret.
   - *Cloudflare Email Service (beta, alternative):* enable Email Service sending for the domain in the dashboard and let it add its DNS records (the account may need beta access). Then set `MAIL_PROVIDER: "cloudflare"` and uncomment the `send_email` binding in `wrangler.jsonc`.
   - Either way the domain needs **SPF**, **DKIM** (the provider's records) and **DMARC** (start with `_dmarc TXT "v=DMARC1; p=none; rua=mailto:<you>"`, tighten to `quarantine` once mail flows).
5. **Create the resources in the EU** (logged in with `npx wrangler login`):
   ```sh
   npx wrangler d1 create matilde-directory-staging --jurisdiction eu
   npx wrangler d1 create matilde-directory --jurisdiction eu
   npx wrangler r2 bucket create matilde-blobs-staging --jurisdiction eu
   npx wrangler r2 bucket create matilde-blobs --jurisdiction eu
   ```
   Put the two printed D1 `database_id`s into `wrangler.jsonc` (replacing `REPLACE_WITH_STAGING_D1_ID` / `REPLACE_WITH_PRODUCTION_D1_ID`) and commit. The R2 jurisdiction can't be changed later. Durable Objects need no setup; the Worker pins them to `eu`.
6. **Secrets:** `TOKEN_SIGNING_KEY` and `CODE_PEPPER` for both environments (table above), plus `RESEND_API_KEY` if used.
7. **Migrate and deploy staging, then production:**
   ```sh
   npm run migrate:staging && npm run deploy:staging
   curl https://sync-staging.matilde.page/v1/health
   npm run migrate:production && npm run deploy:production
   curl https://sync.matilde.page/v1/health
   ```
8. **GitHub (for a later deploy workflow):**
   - Create a Cloudflare API token (My Profile → API Tokens → Create Token → "Edit Cloudflare Workers" template), limited to this account and the domain's zone, and add **Account → D1 → Edit**. The template already has Workers Scripts (includes Durable Objects), Workers R2 Storage, Workers Routes and Account Settings read. If deploying the custom domain reports a permission error, add **Zone → DNS → Edit**.
   - Repository → Settings → Secrets and variables → Actions: add `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` (Dashboard → Workers & Pages → Account ID).
   - Repository → Settings → Environments → New environment `production`: required reviewer = the owner, deployment branches = `main` only. Move the two secrets into this environment if only production deploys should see them.
   - No deploy workflow exists yet; deploys are manual (`npm run deploy:*`) until one is added.

## Operations

- **Logs:** Workers Logs (observability is on). Each request logs method, route pattern, status, duration and error code; never bodies, tokens, codes, emails or IPs.
- **Daily cron** (03:17 UTC) deletes expired codes, rate counters and sessions.
- **Backups:** Durable Object point-in-time recovery (30 days) and D1 Time Travel (30 days); everything is ciphertext.
- **Schema changes:** D1 through `migrations/` (`wrangler d1 migrations create DB <name>`); the Durable Object migrates itself on start (`schema_version` in its `meta` table), additive only. Keep every change compatible with the previous app version.
