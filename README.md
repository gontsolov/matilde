# Matilde

A native macOS writing app with a quiet, focused editor and space to explore alternate drafts.

Working names: **Matilde** / **Tilde**.

The first local build uses SwiftUI, an AppKit Markdown editor, and SQLite. AI is deferred; the first draft canvas is implemented.

Build the app with `bash scripts/build-app.sh`, then open `build/Matilde.app`. Requires Xcode with Swift 6; the current build has been compiled on macOS 26.

On first launch, **Start writing** creates or reuses `Documents/Matilde`. **Choose another folder** selects a custom workspace. Matilde remembers your workspace and editing state afterward.

Documents and branches are ordinary Markdown files. Goals, draft relationships, session state, and branching snapshots live in the workspace's hidden `.matilde` folder.

See [the product and architecture notes](docs/architecture.md) for agreed decisions, deferred features, and open questions.

Canvas behavior and remaining work: [zoom out to a board of pinned drafts](docs/canvas-followup.md).
