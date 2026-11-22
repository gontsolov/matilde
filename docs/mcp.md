# Matilde for AI tools (remote MCP server, AI-18)

A remote [Model Context Protocol](https://modelcontextprotocol.io) server that lets an AI tool the user chooses (claude.ai, Claude Desktop, ChatGPT, Cursor, …) read, search and change that user's synced notes, and leave feedback about Matilde. It is **opt-in, per connection, scoped, expiring and revocable**. Nothing changes for anyone who never connects a tool.

- **Production:** `https://mcp.matilde.page/mcp`
- **Staging:** `https://mcp-staging.matilde.page/mcp`

Code: `server/src/mcp/` (served by the sync Worker, see "Where it runs"). Wire format of the notes: [sync-encryption.md](sync-encryption.md), [sync-model.md](sync-model.md), [server/PROTOCOL.md](../server/PROTOCOL.md).

## The trade-off, stated plainly

Matilde's sync is end-to-end encrypted: the server stores ciphertext and never has the account key (AK). An AI tool talks to the server, not to the user's Mac, so **for the server to answer a tool it has to be able to decrypt**. Connecting a tool therefore deliberately gives the server, for that connection and while it lasts, the ability to decrypt the user's notes. This is the one place where Matilde's server ever handles plaintext, and the user agrees to it on the consent screen in those words.

How Matilde keeps that as small as possible, so your notes stay yours:

1. **The Matilde key never leaves the browser.** The consent page unwraps the account key ring in the browser (WebCrypto) from the key slots, exactly like a new device does, and only hands the server a *grant-wrapped* copy of the ring plus the secret for that one grant.
2. **Split storage, so no single store is enough.** The grant-wrapped ring sits in D1 (`mcp_grants.wrapped_ring`); the grant secret `G` that unwraps it lives only inside the OAuth token's encrypted props (KV-style storage, encrypted with a key derived from the access/refresh token itself, which the server stores only as a hash). D1 alone, the props store alone, or a database dump without a live token cannot decrypt anything.
3. **Decrypt per request, in memory, nothing kept.** Each tool call loads the grant, unwraps the ring with `G`, decrypts only the records it needs, answers, and drops everything. No plaintext is written to D1, KV, R2, logs or the audit trail, and there is no cache.
4. **Revocation is cryptographic, not just a flag.** Revoking (from the Mac or iPhone app) deletes `wrapped_ring` and the OAuth grant; any token that still exists unwraps nothing.
5. **Short, explicit lifetimes.** A connection lasts 1, 7, 30 (default) or 90 days, chosen on the consent screen. After that the user connects again.
6. **Least privilege.** Scopes are chosen per connection; editing is off by default.

Honest limits (also on the privacy page):

- **While a connection is active, the server can decrypt every note.** Read-only, comment-only and similar scopes are enforced by server policy, not by cryptography: the ring the server holds decrypts everything for every key epoch it was given. A compromised server with a live token could read the notes.
- **The AI tool sees what it reads.** Note text a tool fetches goes to that tool's provider (Anthropic, OpenAI, Cursor, …) under *their* terms. Matilde can't control or delete it.
- **Revoking stops future access, not past reads.** To be sure even a copied ring is useless, rotate the account key (or regenerate the Matilde key and rotate) after revoking.
- **Feedback-only connections** need no account and no key; they can only send feedback.

## Where it runs

The MCP server is part of the existing sync Worker (`matilde-sync` / `matilde-sync-staging`), on its own custom domain (`mcp.matilde.page`, `mcp-staging.matilde.page`). Requests are routed by host name: the MCP host gets the OAuth provider and the MCP endpoint; the sync host is unchanged. This keeps one deploy, one D1 database (EU jurisdiction) and direct access to the per-user Durable Object, and needs **no new Cloudflare resources**:

- OAuth state (clients, grants, token hashes) is stored by `@cloudflare/workers-oauth-provider` through a small KV-compatible adapter over D1 (`mcp_oauth_kv`), not in a separate KV namespace, so it stays in the EU D1 database and the deploy needs no extra binding.
- `MCP_ENABLED` turns it on per environment (`"1"` on staging, `"0"` on production until the owner has tried staging). When off, the MCP host answers `404` and the connections API on the sync host still works (it lists nothing).

## OAuth 2.1

- Library: `@cloudflare/workers-oauth-provider`. Authorization code with PKCE (S256) only, no implicit flow. Public clients via Dynamic Client Registration (`/oauth/register`) and Client ID Metadata Documents (CIMD, which claude.ai and ChatGPT use). Discovery at `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource` (RFC 9728), `WWW-Authenticate` on `401`.
- Endpoints on the MCP host: `/authorize` (our consent page), `/oauth/token`, `/oauth/register`, `/mcp` (Streamable HTTP, stateless, JSON responses).
- Access tokens live 1 hour; refresh tokens are rotated and live at most as long as the grant (`refreshTokenTTL` 90 days, idle 30 days), but the grant's own `expires_at` in D1 is what counts on every request.
- Reconnecting the same tool replaces its previous connection (old grant revoked).

## Scopes

| Scope | Consent default | Tools |
| --- | --- | --- |
| `notes:read` | on | `list_notes`, `search_notes`, `read_note` |
| `notes:comment` | on | `add_comment` |
| `notes:create` | on | `create_note` |
| `notes:edit` | **off** | `edit_note` |
| `feedback` | on | `leave_feedback` |

`tools/list` only shows the tools a connection's scopes allow, and every call checks the scope again. Any notes scope needs the key step; `feedback` alone doesn't.

## Consent flow

`GET /authorize` (after the library has validated client, redirect URI and PKCE) renders the consent page. It shows the client's name (escaped; marked "not verified" for self-registered clients, with the verified domain for CIMD clients), where access will be sent (redirect host, with a warning for apps on this computer), the scopes as checkboxes and the duration. The page is served with `frame-ancestors 'none'`, a strict CSP (`script-src 'self'`), no third-party resources.

1. **Email.** The user types their Matilde account email; `POST /connect/code` sends a sign-in code through the existing email-code pipeline (same rate limits, same mail, same hashed storage).
2. **Code.** `POST /connect/verify` checks it (5 attempts, 10 minutes). It never creates an account or a device session. On success it returns a short-lived login token (random, stored hashed in `mcp_logins`, 15 minutes, single use) plus the account's `userId`, `keyId`, `keyCheck` and key slots, i.e. what `GET /v1/keys` returns to a device.
3. **Matilde key.** The user types their 12 words (or legacy `MTLD-` code). In the browser: parse and checksum (BIP39 / Crockford), derive the slot secret, unwrap the `recovery` slot, verify `keyCheck`, unwrap `previous-keys` if present. Wrong key → "That key doesn't open this account". The key and the unwrapped ring are never sent.
4. **Grant wrap.** The browser picks `grantId` (UUID) and `G` (32 random bytes) and seals the ring:

   ```
   ring       = count(1) | (keyId(2) | key(32)) × count      current epoch first
   wrapped    = 0x01 | salt(32) | nonce(12) | AES-256-GCM(ring) | tag(16)
   KEK        = HKDF-SHA256(G, salt, "matilde/mcp/v1/grant")
   AAD        = fields("matilde/mcp/v1/grant", userId, grantId)
   ```

5. **Approve.** `POST /connect/approve` with the consent handle, login token, scopes, duration, `grantId`, `wrapped` and `G`. The server unwraps it in memory and checks the current key against the account's `keyCheck` (so a broken page can't create a useless grant), stores the `mcp_grants` row (wrapped ring only, never `G`), and completes the authorization with props `{ userId, grantId, grantSecret: G, scopes }`. The browser follows the redirect back to the AI tool.

"Feedback only" skips steps 1–4: the grant gets a random anonymous user id and no ring.

The consent handle from the library is bound to the browser by a `__Host-` cookie, works once and expires after 10 minutes; the login token is sent in a header, so the JSON endpoints can't be triggered cross-site.

## Per request

1. The OAuth provider validates the bearer token (audience = the MCP resource) and decrypts the props.
2. Load `mcp_grants` by `grantId`: must exist, belong to `userId`, not be revoked, not be expired. Otherwise `401` (the tool reconnects).
3. Rate limits (D1 fixed windows): per grant 60 calls/minute and 1000/day, writes (`create_note`, `add_comment`, `edit_note`) 60/hour per grant, per account 2000 calls/day across grants; `leave_feedback` additionally goes through the feedback limits.
4. Run the tool. Write one audit row; set `last_used_day` (`YYYY-MM-DD`, day resolution on purpose).

### Tools

- `list_notes({folder?, limit?, cursor?})`: titles, ids, folder, created/edited times. Main drafts and alternate drafts are listed; trashed notes aren't.
- `search_notes({query, limit?})`: case- and accent-insensitive substring search over titles and bodies, at most 20 results with short snippets. Bounded: at most 2000 notes and 25 MB of ciphertext are decrypted per call; bodies stored as blobs (over 3 MiB) are skipped and reported.
- `read_note({id})`: title, folder, goal, word count, Markdown body, and the note's private comments that aren't archived (quote, text, author).
- `create_note({title, text, folder?})`: a new main draft (draft and body records); the title becomes the file name, made unique like the app does ("Title 2").
- `add_comment({id, quote, comment})`: a private comment anchored on `quote`, which must occur exactly once in the note. Stored as a normal comment record with the new optional `author` field (the tool's name); the apps show "From <author>". Apps older than this see it as an ordinary private comment.
- `edit_note({id, edits:[{old_text, new_text}]})`: exact replacements, each `old_text` must occur exactly once. Pushed with compare-and-swap on the body; if the note changed meanwhile, the call fails with "the note changed, read it again" instead of overwriting.
- `leave_feedback({message, kind?, replyEmail?})`: goes through the same pipeline as in-app feedback (`/v1/feedback`: D1 queue, Linear issue, retries). The issue says "Sent from <client> via MCP"; no account id, email or note content is attached.

Writes use `grantId` as the device id in the HLC, so they merge with the apps like any other device's edits. Notes the server can't decrypt (a newer key epoch than the ring, unknown schema) are skipped, never rewritten.

## Revocation and visibility

- **Apps:** Settings → Sync → "Connected AI tools" on the Mac and iPhone lists each connection (tool name, where it sends data, scopes, connected, expires, last used) with **Revoke**. Shared logic in MatildeKit (`ConnectedAITool`, `HTTPSyncTransport.connections()`/`revokeConnection(_:)`).
- **Sync API** (normal device access token): `GET /v1/connections`, `GET /v1/connections/{id}/activity` (last 100 audit rows), `DELETE /v1/connections/{id}`. Revoking sets `revoked_at`, deletes `wrapped_ring` and revokes the OAuth grant.
- Deleting the account deletes all its connections. Rotating the account key doesn't revoke connections (they keep only the epochs they were given, so new notes written under the new key become unreadable to them); revoke and reconnect.

## Audit log and retention

`mcp_audit` holds `(grant, account, time, tool name, outcome code)`: never arguments, note ids, titles, text or queries. Kept 90 days. Revoked or expired grants are deleted 30 days after they end (the row, the audit rows stay until their own 90 days). Login tokens are deleted after 15 minutes. Worker logs carry the route, status and tool name only.

## Files

- `server/src/mcp/index.ts`: host routing, OAuth provider options. `consent.ts`: consent page and `/connect/*`. `protocol.ts`: JSON-RPC (`initialize`, `ping`, `tools/list`, `tools/call`). `tools.ts`: the seven tools. `notes.ts`: reading and writing records with the ring. `crypto.ts`: envelopes, slots, grant wrap, framing. `grants.ts`: scopes, limits, audit, revocation. `kv.ts`: the D1 KV adapter. `routes.ts`: `/v1/connections`.
- `server/src/mcp/web/connect.js`: the consent page's browser module. After editing it run `pnpm run gen:mcp-assets` (it is embedded into `assets.generated.ts`; `pnpm run typecheck` fails when that is stale).
- `server/migrations/0005_mcp.sql`: `mcp_grants`, `mcp_audit`, `mcp_logins`, `mcp_oauth_kv`.

## Owner setup

Nothing to create in Cloudflare: the deploy adds the custom domains and the CI migration step adds the tables.

1. Merge the PR. `server.yml` applies migration `0005_mcp.sql` and deploys staging, which serves `mcp-staging.matilde.page` (the custom domain and certificate are created by `wrangler deploy`; first time can take a few minutes).
2. Try it on staging (below, with the staging URL) with a staging account.
3. To turn on production: set `MCP_ENABLED` to `"1"` under `env.production.vars` in `server/wrangler.jsonc` (a one-line PR), merge, approve the `production` deployment.
4. Optional: add a "Feedback" label id in `LINEAR_LABEL_FEEDBACK` to tell MCP feedback apart (it's also marked in the issue body).

## Connecting a tool

Use `https://mcp.matilde.page/mcp` (staging: `https://mcp-staging.matilde.page/mcp`). Each tool opens the Matilde consent page in the browser; sign in with your email code, type your Matilde key, pick what the tool may do and for how long.

- **claude.ai** (Pro, Max, Team, Enterprise): Settings → Connectors → Add custom connector → paste the URL → Connect. Then enable "Matilde" in a chat's tools menu.
- **Claude Desktop:** Settings → Connectors → Add custom connector → paste the URL (remote connectors added on claude.ai show up in Desktop too).
- **ChatGPT** (Plus/Pro/Business with developer mode): Settings → Apps & Connectors → Advanced → Developer mode on → Create → MCP server URL → Authentication: OAuth → Create, then enable it in a chat.
- **Cursor:** Settings → MCP → Add new MCP server, or in `~/.cursor/mcp.json`: `{ "mcpServers": { "matilde": { "url": "https://mcp.matilde.page/mcp" } } }`, then click "Login".
- **Others** (VS Code, Claude Code, …): any client that supports remote MCP with OAuth: `claude mcp add --transport http matilde https://mcp.matilde.page/mcp`.

## Tests

`server/test/mcp.test.ts` (run with `pnpm test` in `server/`): crypto against `docs/sync-vectors/v1.json` (records, fields, slots, key checks, padding, grant wrap), the browser consent script `connect.js` (imported into the Workers test runtime; Matilde keys, legacy codes, unlocking the vector slots, a wrap the server opens), the grant lifecycle (consent → token → tools → expiry → revoke), scope filtering and enforcement, rate limits, audit content, revocation from the sync API, and that records written by the server decrypt and parse like the apps' records.
