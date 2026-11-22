# Matilde sync protocol, v1

The contract between the Matilde apps (Swift client, SYNC-07) and the sync server in this directory. Design background: the project's cloud sync plan (SYNC-04 to SYNC-07). The server never needs plaintext: every record is encrypted on the device, and the server only stores ciphertext plus the cleartext envelope below.

## Basics

- **Base URL:** `https://sync.matilde.page/v1` (staging: `https://sync-staging.matilde.page/v1`).
- **Transport:** HTTPS with JSON bodies (`Content-Type: application/json`), except blob bodies (raw bytes) and the WebSocket.
- **Auth:** `Authorization: Bearer <accessToken>` on everything except `/v1/health`, `/v1/auth/email/*`, `/v1/auth/refresh` and `/v1/feedback` (optional there).
- **App build:** send `X-Matilde-Build: <integer build number>` on every request. If the server's minimum build is higher, every `/v1` request returns `426 upgrade_required`; the app should ask the user to update and stop syncing.
- **Ids:** all ids (record, blob, device, session, slot) are UUIDs in **lowercase** canonical form. Uppercase is rejected (`400`), because ids are part of the encryption's associated data and must be byte-identical everywhere. Swift: `uuid.uuidString.lowercased()`.
- **Binary values** in JSON (`ct`, `wrappedKey`, `keyCheck`, `deviceNameCt`) are standard base64 **with** padding.
- **Times** are milliseconds since the Unix epoch (UTC), except `lastSeenDay` (`YYYY-MM-DD`).

### Errors

Every error is JSON with an HTTP status:

```json
{ "error": { "code": "invalid_request", "message": "changes[0].hlc is malformed" } }
```

Clients act on `code`, not `message`. Codes in use:

| Status | Code | Meaning / client action |
| --- | --- | --- |
| 400 | `invalid_request`, `invalid_email`, `invalid_code` | Fix the request; for `invalid_code` let the user retry or request a new code |
| 401 | `unauthorized` | Access token missing/expired/invalid: refresh, then retry once |
| 401 | `invalid_refresh_token`, `refresh_token_reused`, `session_revoked` | Session is gone: delete stored tokens, show sign-in |
| 403 | `device_limit` | 10 devices already; remove one from another device |
| 404 | `not_found` | |
| 409 | `key_conflict` | Account key changed; re-fetch `/v1/keys` |
| 410 | `account_deleted` | The account was deleted; sign out locally |
| 411 | `length_required` | Blob upload without `Content-Length` |
| 413 | `batch_too_large`, `record_too_large`, `blob_too_large`, `quota_exceeded` | Split the batch / report to the user |
| 426 | `upgrade_required`, `websocket_required` | Update the app / use a WebSocket upgrade |
| 429 | `rate_limited` | Wait `Retry-After` seconds |
| 502 | `mail_failed` | Code email could not be sent; try again later |
| 502 | `feedback_delivery_failed` | Feedback is stored (`queued: true`) and retried by the server; tell the user it will arrive shortly |
| 503 | `feedback_not_configured` | Feedback is stored (`queued: true`) but the server has no Linear key yet; same message to the user |
| 5xx | `internal_error` | Retry with backoff |

## Sign-in and sessions

### Email code

1. `POST /v1/auth/email/start` `{ "email": "anna@example.com" }` → `202 { "ok": true, "expiresIn": 600 }`.
   Sends a 6-digit code. The response is the same whether or not an account exists. A new request replaces the previous code. Limits: 3 per address per 15 minutes, 10 per address per day, 20 per network (/24 or /48) per hour, plus a global daily cap; over a limit → `429` with `Retry-After`.
2. `POST /v1/auth/email/verify`
   ```json
   { "email": "anna@example.com", "code": "123456", "deviceId": "<uuid>", "platform": "macos", "deviceNameCt": "<base64, optional>" }
   ```
   → `200`
   ```json
   { "accessToken": "…", "accessTokenExpiresIn": 900, "refreshToken": "mrt1.…", "sessionId": "<uuid>", "userId": "<uuid>", "isNewAccount": true }
   ```
   - `deviceId`: random UUID created once per app install and kept (it is also the device part of the HLC).
   - `platform`: `macos`, `ios`, `ipados`, `web`, `android` or `other`.
   - `deviceNameCt`: the device name encrypted with the account key (SYNC-06); the server never sees "Anna's MacBook". Omit before the key exists and set it later with `PATCH /v1/devices/{sessionId}`.
   - A code allows 5 attempts, then it is burned (`invalid_code` from then on). Codes expire after 10 minutes and work once.
   - Signing in again with the same `deviceId` replaces that device's old session.
   - An account allows 10 devices (`403 device_limit`).

### Tokens

- **Access token:** a JWT (EdDSA), valid 15 minutes. Treat it as opaque. Its claims are `sub` (userId), `sid` (sessionId), `did` (deviceId).
- **Refresh token:** `mrt1.<sessionId>.<secret>`, opaque; valid until 90 days without use. **Every refresh returns a new refresh token; store it before using the new access token.** Keep both tokens in the Keychain (`…ThisDeviceOnly`).
- `POST /v1/auth/refresh` `{ "refreshToken": "…" }` → same shape as verify (without `isNewAccount`).
  - Presenting an old, already-rotated refresh token signs the session out (`401 refresh_token_reused`): someone may have copied it.
  - Exception: if a refresh response got lost, retrying with the *same* token within 30 seconds works once more and returns a fresh pair.
  - Serialize refreshes per device (one in flight at a time).
- `POST /v1/auth/logout` → `204`. Revokes the calling session.

Refresh proactively shortly before `accessTokenExpiresIn` runs out, or on `401 unauthorized`.

### Devices

- `GET /v1/devices` → `{ "devices": [{ "sessionId", "deviceId", "platform", "nameCt", "createdAt", "lastSeenDay", "current" }] }`
- `PATCH /v1/devices/{sessionId}` `{ "deviceNameCt": "<base64>" | null }` → `204`
- `DELETE /v1/devices/{sessionId}` → `204`. The device's refresh token stops working immediately, its WebSockets close with code `4001`, and its access token dies within 15 minutes.

Revoking, renaming, deleting the account and writing key slots need a session that still exists; a revoked device gets `401 session_revoked` even with an unexpired access token.

### Account

- `GET /v1/account` → `{ "userId", "createdAt", "identities": [{ "provider": "email", "email", "createdAt" }] }`
- `DELETE /v1/account` `{ "confirm": "delete my account" }` → `204`. Deletes all records, blobs, sessions, identities and key slots immediately. Sockets close with `4002`. Backups (point-in-time recovery, ≤ 30 days) contain ciphertext only.

### Sign in with Apple

Not implemented yet (needs DIST-02). It will be `POST /v1/auth/apple` with the identity token and raw nonce, returning the same token pair; accounts can then have an `apple` identity next to `email`.

## Records

### Envelope

The server sees only this envelope; everything else is inside `ct`.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | Record id (existing Matilde UUIDs) |
| `type` | int | See the type table. 1–63 accepted, so new types need no server change |
| `hlc` | string | Hybrid logical clock of this version |
| `baseHlc` | string or null | Push only: the version this edit started from (CAS types) |
| `deleted` | bool | Tombstone |
| `keyId` | int ≥ 1 | Account-key epoch that encrypted `ct` |
| `blobId` | UUID or null | Blob this record references (assets) |
| `rekey` | bool | Push only, optional: re-encryption under a newer key (see below) |
| `ct` | base64 or null | Ciphertext; required unless `deleted`, null in tombstones |
| `deviceId` | UUID | Pull only: the device that pushed this version (from its session) |
| `size` | int | Pull only: ciphertext bytes (0 for tombstones) |
| `seq` | int | Pull only: server sequence number |

### Types

| `type` | Name | Conflict rule |
| --- | --- | --- |
| 1 | draft | LWW |
| 2 | body | **CAS** |
| 3 | snapshot | LWW (immutable in practice) |
| 4 | stash | **CAS** |
| 5 | asset | LWW |
| 6 | comment | LWW |
| 7 | thread | LWW |
| 8 | message | LWW (append-only in practice) |
| 9 | readMarker | LWW |
| 10 | trashed | LWW |
| 11 | settings | LWW |

### HLC

`<ms:13>.<counter:5>.<deviceId>`, e.g. `1763500000000.00042.6f1c…-…`. Milliseconds zero-padded to 13 digits, counter to 5, then the lowercase device UUID. Because of the fixed widths, **string comparison is clock order**; the server compares HLCs as strings. An HLC more than 5 minutes ahead of the server clock is rejected.

### Encryption (summary; specified in SYNC-06)

`ct` = `version | keyId | salt | nonce | ciphertext | tag`, AES-256-GCM under `HKDF-SHA256(AK, salt, "matilde/v1/record")`. Associated data: `"matilde/v1" | userId | id | type | hlc | deleted | keyId`, so the server can't move ciphertext between records, types, accounts or versions. Pad the plaintext (Padmé buckets) before encrypting. The server never checks any of this; it just stores bytes.

### Push

`POST /v1/sync/push`

```json
{
  "deviceId": "<uuid, optional; must match the session>",
  "changes": [
    { "id": "<uuid>", "type": 2, "hlc": "…", "baseHlc": "…", "deleted": false, "keyId": 1, "blobId": null, "ct": "<base64>" }
  ]
}
```

At most 200 changes and 4 MiB of decoded ciphertext per push (6 MiB request), at most 3 MiB per record. Changes are applied in order, all in one transaction. For each change:

1. HLC more than 5 minutes in the future → rejected `clock`.
2. Same `id` and same `hlc` already stored → **accepted, no-op** (safe retries). With `rekey: true`, a higher `keyId` and both not deleted, the ciphertext is replaced instead (key rotation; the HLC stays).
3. Stored `hlc` is newer than the incoming one → rejected `stale`, with the stored row.
4. CAS type (body, stash) and a stored row exists whose `hlc` ≠ `baseHlc` → rejected `conflict`, with the stored row. Creating one (`baseHlc: null`) when it already exists is a conflict too, as is editing a body someone tombstoned.
5. `blobId` set but that blob was never uploaded → rejected `blob_missing` (upload first).
6. Over the 1 GB record quota → rejected `quota`.
7. Otherwise stored with the next `seq`. A tombstone drops the ciphertext and releases its blob.

Response `200`:

```json
{
  "accepted": [{ "id": "<uuid>", "seq": 41 }],
  "rejected": [{ "id": "<uuid>", "reason": "conflict", "row": { "id": "<uuid>", "type": 2, "hlc": "…", "deviceId": "<uuid>", "deleted": false, "keyId": 1, "size": 1234, "blobId": null, "seq": 40, "ct": "<base64>" } }],
  "maxSeq": 41,
  "epoch": "<uuid>"
}
```

`row` is present for `stale` and `conflict`. Client handling:

- **stale (metadata):** decrypt `row`, merge field by field using your per-field HLCs, push the merged record with a new HLC.
- **conflict (body/stash):** keep the server text as the draft and turn the local text into a conflict branch in the same family; then continue from `row.hlc` as the new base.
- **clock:** fix the HLC (adopt server time, `Date` header) and retry.
- **blob_missing:** upload the blob, then retry.

After an accepted push the server nudges the user's other devices.

### Pull

`GET /v1/sync/pull?since=<seq>&limit=<1…500>` (default 500)

```json
{ "rows": [ { "id", "type", "hlc", "deviceId", "deleted", "keyId", "size", "blobId", "seq", "ct" } ],
  "hasMore": false, "maxSeq": 41, "nextSince": 41, "epoch": "<uuid>", "resync": false }
```

- Rows come in `seq` order, each record at most once (its latest version). Pages also stop at about 8 MiB of ciphertext.
- Apply a page in one local transaction, then store `nextSince` **and** `epoch`. Repeat while `hasMore`.
- A new device starts at `since=0`.
- If `epoch` differs from the stored one, or `resync` is true, the server's store was reset (account reset or restore): discard the cursor and pull from 0, merging by id and HLC.
- Tombstones are kept (envelope only, `ct: null`).
- Your own pushes come back in pulls too; skip rows whose `hlc` you already have.

Pull on launch, wake, network return, after a nudge, and every 60 s while active as a fallback.

### Change nudges (WebSocket)

`GET /v1/sync/ws` with a WebSocket upgrade and the usual `Authorization` header.

- On connect the server sends `{"type":"hello","seq":N,"epoch":"…"}`.
- After another device's accepted push: `{"type":"changed","seq":N}`. Pull if `N` is above your cursor. Your own pushes don't nudge you.
- Send the text `ping` (e.g. every 30–60 s); the server answers `pong` without waking up. Nothing else needs to be sent.
- Close codes: `4001` session revoked (sign out), `4002` account deleted. Otherwise reconnect with backoff; a missed nudge only costs latency because of the polling fallback.
- At most 20 sockets per account (`429`).

## Blobs

Encrypted images and other files (encrypted on the device in 64 KB chunks, per SYNC-06).

- `PUT /v1/blobs/{blobId}` with the raw encrypted bytes and `Content-Length` (≤ 64 MiB) → `201 { "blobId", "size", "existed": false }`. Blobs are immutable: uploading an id that already exists returns `200 { …, "existed": true }` and keeps the original.
- `blobId` is a random UUID made by the client, **not** a content hash (which would reveal identical images).
- Upload first, then push the record that references it (`blobId`).
- `GET /v1/blobs/{blobId}` → the bytes (`application/octet-stream`), `404` if unknown.
- Garbage collection: an uploaded blob no record references is deleted after 7 days; a blob whose last referencing record is tombstoned or re-pointed is deleted 30 days later.
- Quota: 5 GB of blobs per account.

## Key slots (storage for SYNC-06)

The server stores wrapped copies of the account key; it can't unwrap them.

- `GET /v1/keys` → `{ "keyId": 1 | null, "keyCheck": "<base64>" | null, "slots": [{ "slotId", "kind", "keyId", "params", "wrappedKey", "updatedAt" }] }`
- `PUT /v1/keys`
  ```json
  { "expectedKeyId": null, "keyId": 1, "keyCheck": "<base64 HMAC(AK, \"check\")>",
    "slots": [{ "slotId": "<uuid>", "kind": "recovery", "params": null, "wrappedKey": "<base64>" }] }
  ```
  Replaces the check value and all slots atomically. `expectedKeyId` must equal the stored `keyId` (`null` when none exists), otherwise `409 key_conflict`. This stops two devices that turn on sync at once from both creating an account key: the loser fetches the winner's key instead. 1–8 slots; `kind` is lowercase (`recovery`, `passphrase`, …); `params` is an opaque string (e.g. Argon2id parameters as JSON).

## Feedback

In-app feedback ("Send Feedback…") that the server files as an issue in the owner's Linear workspace. It is the only request the apps make that isn't sync, and it carries **only** what the user typed, an optional reply email, and basic diagnostics (since 0.3.2 the apps always send `includeDiagnostics: true` with app, version, build, system version and device model; no toggle, no locale). Never note content, never the account email.

- `POST /v1/feedback`, auth optional. With a valid access token the issue says "Signed in: yes"; the server never looks up who. A missing, expired or invalid token counts as signed out, never as an error.
  ```json
  { "kind": "bug", "message": "The sidebar flickers when…", "replyEmail": "me@example.com",
    "includeDiagnostics": true,
    "diagnostics": { "app": "macos", "appVersion": "0.3.0", "build": "42", "osVersion": "15.1",
                     "deviceModel": "Mac15,3", "locale": "en_US" } }
  ```
  - `kind`: `bug`, `idea` or `other` (default `other`). `message`: 1–5000 characters (code points) after trimming. `replyEmail`: optional, a valid address (`400 invalid_email` otherwise).
  - `includeDiagnostics` is required. When `false`, any `diagnostics` sent are ignored and never stored. When `true`, `app`, `appVersion`, `build` and `osVersion` are required and `deviceModel`, `locale` optional; all are short machine values (restricted character sets).
  - Unknown fields at either level are rejected (`400 invalid_request`). Body at most 32 KiB (`413 batch_too_large`).
- `201 { "ok": true, "id", "status": "sent" }` once the Linear issue exists.
- If Linear can't be reached or the key is missing, the feedback is stored and retried by the server's cron (every 15 minutes, starting 5 minutes after submission, up to 10 attempts): `502 feedback_delivery_failed` or `503 feedback_not_configured`, with `"queued": true` and the `id` next to `error`. The apps treat both as "saved, will reach Filip shortly", not as a failure.
- Rate limits: 5 per hour per network (IPv4 /24, hashed), and a global daily cap (`429 rate_limited` with `Retry-After`).
- Stored payloads are deleted once the issue exists; the bookkeeping row goes after 30 days.

## Usage stats

There is no public stats endpoint. Aggregate counts for the owner's dashboard come from the `StatsApi` Worker entrypoint over a service binding (RPC), which no HTTP request can reach. See [docs/stats.md](../docs/stats.md).

## Limits

| Limit | Value |
| --- | --- |
| Changes per push | 200 |
| Ciphertext per push / per record | 4 MiB / 3 MiB |
| Ciphertext stored inline (above: R2, transparent to clients) | 256 KiB |
| Rows per pull page | 500 (and ≈ 8 MiB) |
| Clock skew allowed | 5 minutes |
| Record storage per account | 1 GB |
| Blob storage per account / per blob | 5 GB / 64 MiB |
| Devices per account | 10 |
| WebSockets per account | 20 |
| Access token / refresh token lifetime | 15 minutes / 90 days unused |
| Sign-in code lifetime / attempts | 10 minutes / 5 |
| Feedback per network per hour / message length / body | 5 / 5000 characters / 32 KiB |

## Not yet in v1

- Sign in with Apple (`identities.provider = "apple"` is reserved).
- `GET /v1/account/export` (GDPR export of the ciphertext rows); the app's Markdown export is the readable export.
- Purging old tombstones (will come with a "too old, full resync" rule announced through `resync`).
