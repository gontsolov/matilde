# MatildeKit

Shared Swift code for the Matilde apps (`apps/macos`, `apps/ios`). Foundation and CryptoKit only: no AppKit, UIKit or SwiftUI.

| Folder | Contents |
| --- | --- |
| `Sources/MatildeKit/Records/` | Portable sync records: HLC, record ids, canonical fields, payloads per type ([sync model](../../docs/sync-model.md)) |
| `Sources/MatildeKit/SyncCrypto/` | End-to-end encryption: account key ring, record/blob envelopes, recovery key, key slots, Keychain store ([sync encryption](../../docs/sync-encryption.md)) |
| `Sources/MatildeKit/Sync/` | Sync client core: wire types, codec, merge rules, `SyncEngine`, HTTPS transport ([sync client](../../docs/sync-client.md)) |
| `Sources/MatildeKitTesting/` | Test doubles shared with the apps' tests: `FakeSyncServer`, `FakeSyncTransport` |
| `Tests/MatildeKitTests/` | Record, crypto, recovery, shared-vector, engine and transport tests |

The workspace store (Markdown files, SQLite, the record ledger and the workspace mirror) still lives in the macOS app; moving it here is IOS-02.

## Checks

```sh
cd packages/MatildeKit
swift test
```

Runs on macOS and on Linux. On Linux, swift-crypto stands in for CryptoKit (the dependency is only declared there). CI runs the tests in the macOS job and in the Linux `kit` job.

The package uses Swift 5 language mode, like the macOS app. Everything the apps use is `public`; keep new API platform-neutral.
