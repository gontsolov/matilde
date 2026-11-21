# MatildeKit

Shared Swift code for the Matilde apps (`apps/macos`, `apps/ios`). Foundation and CryptoKit only: no AppKit, UIKit or SwiftUI.

| Folder | Contents |
| --- | --- |
| `Sources/MatildeKit/Records/` | Portable sync records: HLC, record ids, canonical fields, payloads per type ([sync model](../../docs/sync-model.md)) |
| `Sources/MatildeKit/SyncCrypto/` | End-to-end encryption: account key ring, record/blob envelopes, recovery key, key slots, Keychain store ([sync encryption](../../docs/sync-encryption.md)) |
| `Sources/MatildeKit/Sync/` | Sync client core: wire types, codec, merge rules, `SyncEngine`, HTTPS transport, `WorkspaceSyncStore` (mirror into files and tables) ([sync client](../../docs/sync-client.md)) |
| `Sources/MatildeKit/Onboarding/` | Guided sync setup steps (`SyncOnboardingFlow`), email, code and recovery-key input checks, the recovery key file, shared wording (`SyncOnboardingCopy`), the iPhone first-run tour and pull-to-search state |
| `Sources/MatildeKit/Storage/` | The workspace store: Markdown files, SQLite metadata (`Workspace`, `WorkspaceStore`), the record ledger, trash, sidebar order, note moves, stash storage, board placement |
| `Sources/MatildeKit/Review/` | Review data: private comments (`UserComment`), Ask Matilde reviews and threads (`WritingReview`, `ReviewTracking`, `ThreadTimeline`); stored in SQLite, never in the Markdown |
| `Sources/MatildeKit/Assist/` | Ask Matilde client: `LangdockClient`, reply streaming, prompts, `APIKeyStore` (Keychain), `WritingReviewModel` |
| `Sources/MatildeKitTesting/` | Test doubles shared with the apps' tests: `FakeSyncServer`, `FakeSyncTransport` |
| `Tests/MatildeKitTests/` | Record, crypto, recovery, shared-vector, engine and transport tests |

Since IOS-02 the workspace store, review data and the Ask Matilde client live here, so the Mac and iPhone read and write the same files and database. Keychain and Combine code is behind `#if canImport(Security)` / `canImport(Combine)` and is only compiled on Apple platforms.

## Checks

```sh
cd packages/MatildeKit
swift test
```

Runs on macOS and on Linux. On Linux, swift-crypto stands in for CryptoKit (the dependency is only declared there). CI runs the tests in the macOS job and in the Linux `kit` job.

The package uses Swift 5 language mode, like the macOS app. Everything the apps use is `public`; keep new API platform-neutral.
