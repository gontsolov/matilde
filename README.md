# Matilde

A native macOS writing app with a quiet, focused editor and space to explore alternate drafts.

[Download the latest release](https://github.com/gontsolov/matilde/releases/latest) · macOS 14+ · Apple silicon

Version 0.1.9 and later support Apple silicon only. [Version 0.1.8](https://github.com/gontsolov/matilde/releases/tag/v0.1.8) is the final universal release for Intel Macs.

Open the DMG and drag Matilde into Applications. Early builds are not Apple-notarized; macOS may block first launch. See [installation and release notes](docs/releases.md). Once installed, use **Matilde → Check for Updates…** for new versions.

## Features

- Live-rendered Markdown with the syntax hidden while you write; files stay plain `.md`.
- Alternate drafts: branch a document (⇧⌘B), switch drafts above the title, see a family on the draft board (⌘0), and compare two drafts side by side with both editable.
- Stash (⇧⌘J): a shared Markdown scratchpad for each draft family, opened from the toolbar.
- Private highlight comments (⇧⌘K) in the right margin. They follow their passages and never change your Markdown.
- Ask Matilde (⇧⌘A): optional feedback and conversations about the selection or current paragraph through the Langdock API, with your own key in Keychain. Guidance is editable in Settings → Ask Matilde. Suggested rewrites apply only when you accept them.
- Sidebar with always-visible search, folders and drag-and-drop between folders.
- Tabler interface icons and bundled Newsreader type.

Matilde is built with SwiftUI, an AppKit Markdown editor, SceneKit and SQLite.

Build the app with `cd apps/macos && bash scripts/build-app.sh`, then open `apps/macos/build/Matilde.app`. Requires an Apple silicon Mac with Xcode and Swift 6; CI builds on macOS 15. Tests: `swift test --disable-sandbox` in `apps/macos`.

On first launch, **Start writing** creates or reuses `Documents/Matilde`. **Choose another folder** selects a custom workspace. Matilde remembers your workspace and editing state afterward.

Documents and branches are ordinary Markdown files. Goals, draft relationships, comments, stashes, session state, and branching snapshots live in the workspace's hidden `.matilde` folder.

See [the product and architecture notes](docs/architecture.md) for agreed decisions, deferred features, and open questions.

Features, saved ideas, fixes, and progress: [living roadmap and backlog](ROADMAP.md).

Canvas behavior and remaining work: [zoom out to a board of pinned drafts](docs/canvas-followup.md).

Builds, GitHub Actions, update signing, and optional Apple notarization: [release flow](docs/releases.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `apps/macos/` | The macOS app: Swift package, sources, tests, icon sources, `Config/release.json`, release notes and the build/release scripts |
| `apps/web/` | The matilde.page landing page (Astro, Cloudflare Worker) |
| `server/` | The optional sync server (Cloudflare Worker); see [server/README.md](server/README.md) |
| `docs/` | Product, architecture, sync and release documentation |
| `scripts/` | Repo-wide scripts (shared sync test vectors) |

An iOS app (`apps/ios/`) and shared Swift packages (`packages/`, e.g. the sync engine and encryption) are planned; they don't exist yet.
