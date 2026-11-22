# Sync client (SYNC-07)

The Mac side of cloud sync: the push/pull engine, the workspace mirror, the HTTPS transport and the Settings → Sync tab. It builds on the record model ([sync-model.md](sync-model.md), SYNC-02), the encryption ([sync-encryption.md](sync-encryption.md), SYNC-06) and the server protocol ([server/PROTOCOL.md](../server/PROTOCOL.md), SYNC-04/05). The server needs no change.

Sync is **off by default**. Settings → Sync turns it on, signs in with an email code and sets up the account key.

## Code

The platform-neutral parts (wire, codec, merge, engine, transport and, since IOS-02, the workspace mirror) live in the shared package `packages/MatildeKit/Sources/MatildeKit/Sync/`, so the iOS app uses the same engine and mirror; the macOS controller and Settings tab stay in `apps/macos/Sources/Matilde/Sync/`. The iPhone's controller is `apps/ios/Matilde/SyncController.swift` (no on/off switch: signing in turns sync on).

| File | Responsibility |
| --- | --- |
| `Sync/SyncWire.swift` | Wire types (push change, pull row, responses), live events, server errors, limits, the `SyncTransport` protocol |
| `Sync/SyncCodec.swift` | Framed plaintext (raw JSON, DEFLATE, blob reference), sealing and opening records with SyncCrypto |
| `Sync/SyncMerge.swift` | Pure resolution of a server version against the local copy → `SyncStep`s |
| `Sync/SyncEngine.swift` | `actor SyncEngine`: account binding, pull, push, blobs, key epochs. Foundation only |
| `Sync/WorkspaceSyncStore.swift` | `SyncLocalStore` for a workspace: applies steps to the Markdown files and tables, keeps the ledger in step, inbox for early children |
| `Sync/HTTPSyncTransport.swift` | Server URLs, build header, tokens in the Keychain, sign-in, `SyncSession` (refresh/rotation), HTTPS transport, backoff, WebSocket nudges |
| `Sync/SyncCenter.swift` | `@MainActor` app controller: settings, sign-in, key setup, engine per workspace, triggers, status |
| `Sync/SyncSettings.swift` | The Settings → Sync tab |

Tests: `SyncEngineTests` (25, in MatildeKit, against `FakeSyncServer` from `MatildeKitTesting`, an in-memory model of the server's push/pull/blob rules, and `MemorySyncStore`), `SyncTransportTests` (8, in MatildeKit, HTTP stubbed with `URLProtocol`), `WorkspaceSyncTests` (7, in the macOS app, two real workspaces syncing through the fake server).

## One sync

`SyncEngine.sync()` runs on its own actor, never the main thread:

1. **Track.** `trackSyncChanges()` brings the ledger up to date, so every save since the last sync becomes a pending record.
2. **Bind the account.** The cursor remembers the user id. A different account forgets every server acknowledgement, the cursor and local tombstones (the new account never had those records): full upload, full download.
3. **Pull** pages of 500 since the cursor until `hasMore` is false. Each row is opened with the key ring; a row that fails authentication (tampered, other account, wrong key) is **skipped and counted** (`unreadable`), never applied. A row from an unknown key epoch stops the sync with `unknownKey`; the app fetches `/v1/keys`, rebuilds the ring and runs again. Own versions coming back (same HLC) are acknowledged without decrypting. The cursor is saved after every page, so an interrupted pull resumes. A new store `epoch` or `resync: true` restarts from 0 and re-queues everything the server no longer has.
4. **Push** pending records oldest first: windows of 5000, batches of at most 200 changes and 3.8 MB of ciphertext, at most 10 rounds per sync. Accepted versions are marked. `stale`/`conflict` rejections carry the server row, which is resolved like a pulled row (merged metadata or a conflict branch) and goes out in the next round. `blob_missing` re-uploads the blob. `clock` and `quota` rejections leave the record pending for the next sync (counted; quota shows "Sync storage is full").

Each step is applied as it comes; an error keeps whatever was applied or acknowledged before it.

### Merge rules (`SyncMerge`)

- Unknown locally, or no unpushed local change: take the server version.
- Metadata records with unpushed changes: field by field, newer field clock wins; if the result differs from the server's, it becomes a new local version with the server version as its base.
- Bodies with unpushed changes: the server text stays the draft; the local text becomes a **conflict branch** in the same family ("Title — from MacBook Air"; a remote text that loses a delete race becomes "Title — recovered"). Equal texts and an empty local text are not conflicts.
- Body delete vs edit: the delete stands, the edit survives as a conflict branch. Other types: last writer wins by HLC.
- Stash conflicts keep both texts, the server's first.

### Workspace mirror (`WorkspaceSyncStore`)

- Its own `Workspace` (own SQLite connection, 3 s busy timeout) on the engine's executor. Transactions of 50 records, so the app's own writes wait briefly at most.
- Apply order: conflict branches, then live records parents first (folder, draft, body, snapshot, stash, image, comment, thread, message, read marker, Trash archive), then tombstones in reverse.
- A body or stash file is only overwritten if it is unchanged since the ledger last saw it; otherwise the local edit stays and the next push turns it into a conflict branch.
- Deleted drafts, stashes and images go to the **macOS Trash**, never straight to deletion.
- A path that is taken locally by another draft gets a free name ("Title 2.md") and stays local-only (the record keeps the original path).
- A body before its draft, or a message/read marker before its thread, waits in `sync_inbox` and is applied once the parent arrives.
- After applying, the ledger is updated from the re-derived local state, so applied records are never sent back as local changes (no echo).
- Device-local state (cursor, scroll, board, comparison, window, sidebar) is never synced.

### Blobs and large records

- Images travel as encrypted blobs (`PUT /v1/blobs/{id}`, random blob id, random per-file key in the record). Uploaded blob references are cached per record version (`sync_blobs`), so retries don't re-upload.
- Framed plaintext over ~3 MiB (a very long draft) is uploaded as a blob and the record carries a reference (`0x02` frame, blob id in the envelope).
- Records are compressed with raw DEFLATE when it saves at least 10 % (macOS Compression framework).

## Transport and sessions

- `SyncServer.production` = `https://sync.matilde.page/v1/`, `.staging` = `https://sync-staging.matilde.page/v1/`. The server in use is stored in UserDefaults `sync.serverURL`.
- Release builds (including `bash apps/macos/scripts/build-app.sh`, which builds `-c release`) always use production and show no Server picker. Staging is for testing only (`SyncServerSelection`):
  - persistent: `defaults write app.matilde.local sync.server staging` (quit Matilde first; undo with `defaults delete app.matilde.local sync.server`);
  - one launch: `open build/Matilde.app --args --sync-server staging` (`production` also accepted). The next launch without it goes back to production.
  - Order: launch argument, then the `sync.server` default, then (debug builds only) the Settings picker's stored choice, else production. Unknown values mean production.
  - Debug builds (`swift run`, `swift build`) also show a Server picker (Matilde / Staging) in Settings → Sync.
- If the server chosen at launch differs from the stored one (e.g. staging stored by an earlier build, or the staging override was removed), it is a server change: the app signs out of the old server (revokes the session, forgets its tokens and, if it's a different account, its account key on this Mac), so accounts never mix. Signing in to staging again after that needs its recovery key.
- Every request sends `X-Matilde-Build`: `CFBundleVersion` a.b.c as `a*10000 + b*100 + c` (0.1.19 → 119); development builds send 0. `426 upgrade_required` stops sync and shows "Update Matilde to keep syncing."
- Tokens live only in the Keychain (service `app.matilde.local.sync.session`, account = server host, this device only). The access token is refreshed 60 s before expiry and once after a 401; refreshes are serialized and the rotated refresh token is stored before use. `invalid_refresh_token`, `refresh_token_reused`, `session_revoked` and `account_deleted` (or WebSocket close 4001/4002) end the session: tokens forgotten, sign-in shown.
- Backoff 1–60 s with ±20 % jitter, or `Retry-After`.

## Keys

On sign-in the app fetches `GET /v1/keys`:

- No key yet: makes the account key and a Matilde key (12 words), `PUT /v1/keys` (on `409 key_conflict` another device won: recover instead), stores the ring in the Keychain, shows the Matilde key once on a card with Copy, Save… and Print…, and waits for "I've saved my Matilde key" to be ticked.
- A key exists and the Keychain has it: checked against `keyCheck`, older epochs read from the `previous-keys` slot.
- Otherwise: asks for the Matilde key: 12 word fields with suggestions and a flag for words not in the list (pasting fills all of them), or the old `MTLD-` key behind "I have a key that starts with MTLD". The form shown first follows the recovery slot's `params` hint.

After the key is ready, the device name (computer name) is sent encrypted (`PATCH /v1/devices/{sessionId}`), best effort. Sign out revokes the session and removes the account key from this Mac's Keychain; signing in again needs the Matilde key.

## Triggers

A saved local change (5 s debounce), a `changed`/`hello` nudge on the WebSocket, app activation, wake from sleep, a 60 s poll, and Sync Now. One sync at a time; a trigger during a sync runs another one afterwards. Errors back off. Before each sync the app saves pending edits; after records were applied it rescans drafts and folders, reloads the active draft (existing external-reload path) and its comments and Ask Matilde threads. Quitting never waits for the network.

## Privacy

Logs (`Matilde sync:` in Console) contain counts, HTTP status and error codes or error type names only: never text, titles, paths, emails, codes, tokens or keys. `SyncTokens` and `SyncRecoveryKey` redact themselves in descriptions.

## Deviations from the plan

- **No deltas.** The server stores only the latest version of a record, so bodies travel whole; per-record DEFLATE keeps them small instead.
- **Deletes go to the Trash** on the receiving Mac (drafts, stashes, images), matching the app's Move to Trash.
- **First sync is merge-only:** an existing workspace's records are uploaded and the server's are merged in by id and HLC; nothing is replaced wholesale. Two Macs that each have the welcome document (or any same-named file with a different draft id) end up with "Welcome 2.md" until SYNC-03 matches drafts across Macs; colliding paths stay local-only.
- **Tampered rows are skipped and counted**, not fatal.
- The review `source` input and reply error messages are not synced (local runtime state). `settings` records are ignored for now.
- The build header comes from `CFBundleVersion`.

## Not in this step

- Matching drafts between two Macs that each scanned the same files, identity across external moves: SYNC-03.
- Recovery-kit printing, regenerating the recovery key and full key rotation from the UI (the core supports them), "Reset encryption", a device list.
- A `settings` record (Ask Matilde guidance/model/region).
- Sign in with Apple (needs DIST-02).
