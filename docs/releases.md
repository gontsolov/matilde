# Releases and updates

Matilde is distributed directly from GitHub, not through the Mac App Store.

## Download and update

The stable download is `https://github.com/gontsolov/matilde/releases/latest/download/Matilde.dmg`.
Open the DMG and drag Matilde into Applications. Version 0.1.9 and later target Apple silicon (M1 or later), with macOS 14 as the minimum version. Version 0.1.8 is the final universal release and remains available to Intel users.

Sparkle 2.9.6 checks for new versions and presents its native install/relaunch UI. Manual checks live under **Matilde → Check for Updates…**. Automatic installation is disabled. No writing or workspace content is sent to the update server. The feed request goes to matilde.page, which redirects to GitHub; the download comes from GitHub. System-profile submission is disabled.

The stable feed is `https://matilde.page/appcast.xml` (from the release after 0.3.2). The matilde.page Worker adds one anonymous count per request (app version and macOS major version from the user agent, see [stats.md](stats.md)) and redirects with a 302 to `https://github.com/gontsolov/matilde/releases/latest/download/appcast.xml`, which every release still uploads. The bytes Sparkle receives are the signed GitHub file, so signature checks are unchanged. Installs of 0.3.2 and older have the GitHub address built in and keep checking it until they update once; after that they use the new address. Keep publishing `appcast.xml` as a release asset: it's what both addresses serve. Both the DMG and feed use Sparkle Ed25519 signatures, with the public key embedded in every app bundle. Never edit the generated feed after signing. Updates are verified before extraction. Existing pre-updater development builds need one manual installation.

## Publish a version

1. Merge changes into `main` and check CI.
2. Open GitHub Actions → **Release** → **Run workflow**, select `main`, and enter a version such as `0.1.1`. Alternatively, push a `v0.1.1` tag on a commit already in `main`.
3. The workflow validates version ordering, tests, builds arm64, packages the DMG, signs the archive and feed, uploads all assets to a draft release, then publishes it as latest.

The single release concurrency group prevents overlapping publications. Versions must increase numerically and use three numeric components. Published versions cannot be overwritten. A failed draft release can be retried from the same commit. `apps/macos/Config/release.json` controls local build version, stable bundle identity, update URL, repository, and public signing key. The release version overrides the local default through `MATILDE_VERSION`; keep the default current when beginning a new development cycle.

Version 0.1.8 was universal. Starting with 0.1.9, feeds must contain `sparkle:hardwareRequirements` set to `arm64`; the pinned Sparkle generator infers this from the executable and release verification enforces it before publication. Sparkle 2.9.6 in existing installations rejects incompatible hardware updates. See [Sparkle hardware requirements](https://sparkle-project.org/documentation/publishing/#minimum-system-version-requirements). If the minimum supported macOS version changes, preserve compatible older feed entries before release; do not strand users on an unsupported update. This workflow intentionally does not generate delta updates or prerelease channels yet.

## Signing configuration

Required GitHub Actions secret:

- `SPARKLE_PRIVATE_KEY`: exported contents from Matilde's Sparkle signing key. It authorizes updates to installed copies, so keep it private and backed up. The public half is safe to commit.

The local key is stored in the login Keychain under the Sparkle account `app.matilde.local`. It was generated for this app only. Do not regenerate it for each release. The release scripts can sign locally through that Keychain account without exporting the key. GitHub automation needs the same key installed as the repository secret above; this transfer requires owner authorization.

Actions use pinned official action commits, and pull-request CI has read-only permissions and no signing secrets. The release workflow accepts main-branch history only. Do not give untrusted collaborators write access to release workflow code: repository writers who can change it can potentially use its signing secret. Review workflow changes and protect main before adding collaborators.

## Release signing

### Why ad-hoc releases ask for the keychain password

Matilde's secrets (sync session, sync account key, Langdock key) are items in the login keychain. macOS lets an app read such an item without asking only if the app meets the item's access list and its partition list. Both are tied to the app's code signature:

- An ad-hoc signature has no certificate. Its designated requirement is the build's own hash (`cdhash H"…"`) and its keychain partition is `cdhash:…`. Every release has a new hash, so after every update macOS treats Matilde as a new app and asks again. "Always Allow" only covers that one build.
- A **self-signed** certificate doesn't help. securityd gives a `teamid:` partition only to App Store builds and to Apple-issued Apple Development, Mac Distribution and Developer ID certificates; any other certificate falls back to `cdhash:` like ad-hoc.
- An **Apple-issued** certificate gives a stable `teamid:<TEAM>` partition. `scripts/build-app.sh` also signs the app with an explicit designated requirement, `identifier "app.matilde.local" and anchor apple generic and certificate leaf[subject.OU] = "<TEAM>"`, which every later release signed by the same team meets (Apple Development now, Developer ID later). After one last "Always Allow", updates don't ask.

Since DIST-10 the Mac app also keeps all its secrets in one keychain item (`app.matilde.local.vault`, label "Matilde", `CredentialVault` in MatildeKit), reads it only when sync or Ask Matilde needs it (not at launch), and shows a short note before macOS asks. The first time it runs, it moves the older items into the vault (one prompt per older item, once) and deletes them. While releases stay ad-hoc, there is one prompt per update, for one item.

### Stable signing with an Apple Development certificate

A free Apple ID is enough; no paid membership. On a Mac with Xcode:

1. Xcode → Settings → Accounts → add the Apple ID (it gets a "Personal Team").
2. Select the team → Manage Certificates… → + → Apple Development.
3. Keychain Access → login → My Certificates → right-click "Apple Development: …" → Export as `.p12` with a password.
4. From the repo: `bash apps/macos/scripts/setup-release-signing.sh ~/Desktop/Certificates.p12`. It checks the file in a throwaway keychain, shows the team and expiry, and after confirmation stores the secrets `APPLE_CERTIFICATE_P12` and `APPLE_CERTIFICATE_PASSWORD` with `gh secret set`. Run it without an argument for these steps.

The Release workflow signs with the certificate whenever `APPLE_CERTIFICATE_P12` is set (`CODE_SIGN_IDENTITY` is optional; the certificate's SHA-1 is used otherwise), prints the designated requirement, and fails if the certificate has no Apple team. Without the secret, releases stay ad-hoc.

Caveats:

- Apple Development certificates are meant for development. Signing downloads with one works for the keychain but is outside its intended use; Developer ID is the proper certificate for distribution (DIST-02).
- Releases are still **not notarized**. Gatekeeper's first-launch behaviour is the same as for ad-hoc builds.
- The signature includes the certificate's name (the Apple ID's name) and team ID; anyone can see them with `codesign -dv`.
- The certificate expires after about a year. Make a new one the same way and run the setup script again; the team ID stays the same, so the requirement still matches and updates don't ask.
- Sparkle accepts the change: updates are authenticated by the EdDSA signature, and a new code-signing identity is allowed as long as the new app's signature is valid.

### Notarization (Developer ID, later)

A Developer ID certificate is for direct downloads too; it does not require an App Store submission. It needs the paid Apple Developer Program. Put the Developer ID Application certificate in `APPLE_CERTIFICATE_P12`/`APPLE_CERTIFICATE_PASSWORD`, set repository variable `APPLE_NOTARIZE=true` (the older `APPLE_SIGNING_ENABLED=true` still works), and add the secrets:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD` (app-specific password for notarization)

The workflow then signs with Hardened Runtime, notarizes and staples the app and DMG, and leaves out the "not notarized" first-launch note. Switching from Apple Development to Developer ID under the same team keeps the same designated requirement, so it needs no keychain prompt. That path needs verification with a real Developer ID before claiming notarized distribution.

## Local verification

From `apps/macos/` (the macOS app's package root; release notes are in `apps/macos/release-notes/`):

```sh
cd apps/macos
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests
bash scripts/build-app.sh
bash scripts/package-release.sh
bash scripts/sign-release.sh
```

`codesign --verify --deep --strict` and architecture validation run during packaging. `verify-appcast.py` checks metadata, URL, archive length, version and deployment target, and uses CryptoKit to verify the archive and feed Ed25519 signatures against the committed public key. Sparkle performs cryptographic verification during install; `sign_update --verify` can validate signatures locally. A full update-install test needs two published signed versions and a disposable installed app copy; successful packaging alone is not an end-to-end updater test.

Official references: [Sparkle setup](https://sparkle-project.org/documentation/), [programmatic SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/), and [manual framework signing](https://sparkle-project.org/documentation/sandboxing/#code-signing).

The build script always compiles Matilde for arm64, and packaging rejects any other executable architecture. Sparkle remains the unchanged vendor framework, which includes its own universal helper binaries. Raising the macOS minimum is deferred until a concrete API or maintenance benefit justifies it.
