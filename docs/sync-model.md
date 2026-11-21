# Sync record model (SYNC-02)

The local contract between Matilde's data and the sync engine. Design background: the project plan `plans/cloud-sync.md` (§0, §2). Wire format and server rules: [`server/PROTOCOL.md`](../server/PROTOCOL.md) (PR #25). Encryption of the plaintext: SYNC-06. Transport, pulling and the workspace mirror: SYNC-07.

Code: `packages/MatildeKit/Sources/MatildeKit/Records/SyncRecord.swift` (HLC, ids, canonical fields, record and envelope), `Records/SyncPayloads.swift` (fields per type), `Storage/SyncLedger.swift` (change tracking, tombstones, outbox). Tests: `SyncRecordTests`, `SyncLedgerTests`.

## Source of truth

Nothing about the existing storage changes. Writing stays in the workspace's `.md` files; goals, families, comments, Ask Matilde reviews, snapshots and the Trash archive stay in their existing tables in the workspace database (in Application Support since SYNC-01), stashes and snapshots stay in `.matilde`. Review data (comments, threads, unread state) stays in SQLite and never goes into the Markdown files.

The sync layer only **adds** two tables to the workspace database:

- `sync_records`: one row per record id: `type`, local `entity` key, current `hlc`, `server_hlc` (the version the server last acknowledged or delivered), `deleted`, `schema_version`, `digest` (SHA-256 of the canonical fields), `fields` (per-field digest and HLC as JSON) and `fingerprint` (size and modification time of a backing file).
- `sync_meta`: `ledger_version` and the device's last issued `clock`.

`Workspace.trackSyncChanges()` compares the current local data with `sync_records`. A record whose fields changed gets a new HLC (and every changed field gets that HLC as its field clock); a record whose entity is gone becomes a tombstone (`deleted = 1`, fields dropped). Nothing else is written: not the Markdown, not the app's own tables. The app runs it when a workspace opens and when Matilde quits; the sync engine will run it before each push. Its HLC therefore says when a change was *noticed*, at the latest at quit; SYNC-07 tightens that by tracking before every push.

## Migration of existing data

There is no separate migration step: the first `trackSyncChanges()` on a workspace finds no ledger rows, so every existing entity gets a record with a fresh HLC, all pending. Running it again changes nothing. It is safe to interrupt (one transaction) and to repeat. Existing UUIDs are kept as record ids (lowercased); entities without one get a deterministic id (below), so two Macs migrating the same data derive the same ids. Rows with a non-UUID id are skipped.

## Ids

Record ids are lowercase canonical UUIDs (they are part of the encryption's associated data).

| Record | Id |
| --- | --- |
| draft, snapshot, comment, thread, message | the existing UUID, lowercased |
| body | `derived("body", draftID)` |
| stash | `derived("stash", familyID)` |
| readMarker | `derived("read", threadID)` |
| trashed | `derived("trashed", draftID)` |
| folder | `derived("folder", relativePath)` |
| asset | `derived("asset", relativePath)` |

`derived(kind, key)` is a version 5 (name-based, SHA-1) UUID in Matilde's namespace `6d61746c-6465-5379-6e63-2d7265636f72` over `"<kind>:<key>"` in Unicode NFC, so decomposed and precomposed spellings of a path agree. Python check: `uuid.uuid5(UUID("6d61746c-6465-5379-6e63-2d7265636f72"), "body:<draft id>")`.

## Clock

HLC `<ms:13>.<counter:5>.<deviceID>`, e.g. `1763500000000.00042.6f1c2d3e-…`; string order is clock order (the server compares strings). The device id is a random lowercase UUID per install (`UserDefaults` key `sync.deviceID`), the same id the server's sessions use. The clock never goes backwards: each new HLC is above the last one issued (kept in `sync_meta`), above every version in the ledger and above any server clock passed to `observeSyncClock(_:)`. A counter overflow carries into the next millisecond.

## Record types and fields

Raw type values are the server's. `folder` (12) is new; the server accepts 1…63, so it needs no server change. Times are milliseconds since 1970; ids pointing at other records are record ids; nil optional fields are omitted.

| Type | Fields | Conflict rule |
| --- | --- | --- |
| 1 draft | `path`, `family`, `parent?`, `goal`, `created?` | LWW, field merge |
| 2 body | `draft`, `text`, `edited?` | CAS, conflict branch |
| 3 snapshot | `source`, `child`, `text`, `created?` | LWW (immutable) |
| 4 stash | `family`, `text` | CAS |
| 5 asset | `path`, `size` (the encrypted file becomes a blob in SYNC-07) | LWW |
| 6 comment | `draft`, `body`, `location`, `length`, `quote`, `prefix`, `suffix`, `created`, `modified`, `archived` | LWW, field merge |
| 7 thread | `review`, `draft`, `reviewCreated`, `model`, `revision`, `stale`, `quote`, `prefix`, `suffix`, `explanation`, `replacement?`, `location`, `length`, `status`, `userInitiated?`, `rewriteQuote?`, `rewriteMessage?`, `initialReplacement?` | LWW, field merge |
| 8 message | `thread`, `index`, `role`, `text`, `delivery?`, `replacement?` | LWW (append-only) |
| 9 readMarker | `thread`, `unread` | LWW |
| 10 trashed | `draft`, `path`, `family`, `parent?`, `goal`, `trashedAt?` | LWW |
| 11 settings | reserved, not produced yet | LWW |
| 12 folder | `path` | LWW |

`writing_reviews` stores a review as one JSON blob; the record model normalises each of its comments into a thread (carrying the review's own fields), each message into a message record and the unread flag into a read marker, so reading a thread on one Mac never races an edit of it on another. Not synced: a review's `source` snapshot (anchors fall back to quote/context matching, which the app already does for older reviews) and transient reply errors.

Device-local, never in a record: cursor and scroll, board positions and viewports, comparison state, the active draft and sidebar state, `untitled:` flags, recovery copies, appearance and app icon, Ask Matilde settings and the Langdock key. (Ask Matilde guidance/model/region as a `settings` record is a follow-up.)

## Tombstones

A record whose entity disappears becomes a tombstone once: deleting a comment, trashing a draft (its draft and body records; a `trashed` record appears), removing a folder or image. A tombstoned record that reappears with the same id (for example undo re-inserting a comment) gets a new, live version. A file that exists in the data but can't be read right now is **never** tombstoned: a draft's missing or non-UTF-8 `.md` file, or any file iCloud Drive evicted to a `.name.icloud` placeholder, keeps its last version. Only the draft row going away (Trash) tombstones a body. Tombstones are kept; purging follows the server's "too old, full resync" rule later.

## Portable format

`SyncRecord` is one version of one record. Its cleartext `envelope` matches a push change (`id`, `type`, `hlc`, `baseHlc` for CAS types only, `deleted`); SYNC-06 adds `keyId` and `ct`, SYNC-07 `blobId`. `plaintext()` is what SYNC-06 encrypts (nil for tombstones, which carry no ciphertext):

```json
{"fieldHlcs":{"draft":"…","edited":"…","text":"…"},"fields":{"draft":"…","edited":1763500000000,"text":"# Title…"},"v":1}
```

Canonical JSON: sorted keys, no escaped slashes, so the same record always produces the same bytes. `v` is `SyncRecord.schemaVersion`: adding a field keeps it, renaming or removing one bumps it, and `SyncRecord.decode` rejects a newer version. Padding happens in SYNC-06. The id, type, HLC and deleted flag are not repeated inside: they are the encryption's associated data.

## Outbox

A record is pending while `hlc ≠ server_hlc`. `pendingSyncRecords(limit:)` tracks first, then returns pending records oldest first with their fields and `baseHlc = server_hlc`. `markSyncAccepted(_:)` records the server's acceptance of exactly those versions; a record edited again since stays pending with its newer version.

## Not in this step

- Applying pulled records (the workspace mirror, echo suppression), field merges after `stale`, conflict branches after `conflict`, blobs and records over 3 MiB: done in SYNC-07, see [sync-client.md](sync-client.md). The sync engine runs `trackSyncChanges()` before every push.
- Identity across external moves and matching drafts between two Macs that each scanned the same files (each Mac gives an unknown file its own UUID today): SYNC-03.
- A `settings` record for Ask Matilde guidance/model/region.
