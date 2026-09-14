# Releases and updates

Matilde is distributed directly from GitHub, not through the Mac App Store.

## Download and update

The stable download is `https://github.com/gontsolov/matilde/releases/latest/download/Matilde.dmg`.
Open the DMG and drag Matilde into Applications. Version 0.1.9 and later target Apple silicon (M1 or later), with macOS 14 as the minimum version. Version 0.1.8 is the final universal release and remains available to Intel users.

Sparkle 2.9.6 checks for new versions and presents its native install/relaunch UI. Manual checks live under **Matilde → Check for Updates…**. Automatic installation is disabled. No writing or workspace content is sent to the update server. The feed and download requests go to GitHub; system-profile submission is disabled.

The stable feed is `https://github.com/gontsolov/matilde/releases/latest/download/appcast.xml`. Both the DMG and feed use Sparkle Ed25519 signatures, with the public key embedded in every app bundle. Never edit the generated feed after signing. Updates are verified before extraction. Existing pre-updater development builds need one manual installation.

## Publish a version

1. Merge changes into `main` and check CI.
2. Open GitHub Actions → **Release** → **Run workflow**, select `main`, and enter a version such as `0.1.1`. Alternatively, push a `v0.1.1` tag on a commit already in `main`.
3. The workflow validates version ordering, tests, builds arm64, packages the DMG, signs the archive and feed, uploads all assets to a draft release, then publishes it as latest.

The single release concurrency group prevents overlapping publications. Versions must increase numerically and use three numeric components. Published versions cannot be overwritten. A failed draft release can be retried from the same commit. `Config/release.json` controls local build version, stable bundle identity, update URL, repository, and public signing key. The release version overrides the local default through `MATILDE_VERSION`; keep the default current when beginning a new development cycle.

Version 0.1.8 was universal. Starting with 0.1.9, feeds must contain `sparkle:hardwareRequirements` set to `arm64`; the pinned Sparkle generator infers this from the executable and release verification enforces it before publication. Sparkle 2.9.6 in existing installations rejects incompatible hardware updates. See [Sparkle hardware requirements](https://sparkle-project.org/documentation/publishing/#minimum-system-version-requirements). If the minimum supported macOS version changes, preserve compatible older feed entries before release; do not strand users on an unsupported update. This workflow intentionally does not generate delta updates or prerelease channels yet.

## Signing configuration

Required GitHub Actions secret:

- `SPARKLE_PRIVATE_KEY`: exported contents from Matilde's Sparkle signing key. It authorizes updates to installed copies, so keep it private and backed up. The public half is safe to commit.

The local key is stored in the login Keychain under the Sparkle account `app.matilde.local`. It was generated for this app only. Do not regenerate it for each release. The release scripts can sign locally through that Keychain account without exporting the key. GitHub automation needs the same key installed as the repository secret above; this transfer requires owner authorization.

Actions use pinned official action commits, and pull-request CI has read-only permissions and no signing secrets. The release workflow accepts main-branch history only. Do not give untrusted collaborators write access to release workflow code: repository writers who can change it can potentially use its signing secret. Review workflow changes and protect main before adding collaborators.

## Apple signing (optional, not configured)

Current builds use an ad-hoc code signature and are **not Apple-notarized**. Sparkle signatures authenticate later updates; they do not replace Apple's first-launch checks. macOS may block the initial download, and managed Macs may disallow it entirely. Follow [Apple's instructions](https://support.apple.com/guide/mac-help/mh40616/mac) if you choose to open a trusted build.

A Developer ID certificate is for direct downloads too; it does not require an App Store submission. To add notarization later, set repository variable `APPLE_SIGNING_ENABLED=true`, variable `CODE_SIGN_IDENTITY` to the Developer ID Application identity, and secrets:

- `APPLE_CERTIFICATE_P12` (base64-encoded exported certificate and key)
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD` (app-specific password for notarization)

The workflow then imports the certificate into a temporary keychain, signs Sparkle's nested helpers and app with Hardened Runtime, notarizes and staples the app and DMG, and deletes the temporary keychain. That path needs verification with a real Developer ID before claiming notarized distribution.

## Local verification

```sh
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests
bash scripts/build-app.sh
bash scripts/package-release.sh
bash scripts/sign-release.sh
```

`codesign --verify --deep --strict` and architecture validation run during packaging. `verify-appcast.py` checks metadata, URL, archive length, version and deployment target, and uses CryptoKit to verify the archive and feed Ed25519 signatures against the committed public key. Sparkle performs cryptographic verification during install; `sign_update --verify` can validate signatures locally. A full update-install test needs two published signed versions and a disposable installed app copy; successful packaging alone is not an end-to-end updater test.

Official references: [Sparkle setup](https://sparkle-project.org/documentation/), [programmatic SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/), and [manual framework signing](https://sparkle-project.org/documentation/sandboxing/#code-signing).

The build script always compiles Matilde for arm64, and packaging rejects any other executable architecture. Sparkle remains the unchanged vendor framework, which includes its own universal helper binaries. Raising the macOS minimum is deferred until a concrete API or maintenance benefit justifies it.
