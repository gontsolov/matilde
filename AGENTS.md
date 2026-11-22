# Matilde: agent handoff

## Product and collaboration

Matilde (also called Tilde during naming) is a native macOS writing app. The priority is an excellent, quiet writing experience with independently editable alternate drafts. AI (Ask Matilde) supports the writing; it is not the center of the product.

- Carry requested changes through implementation and appropriate verification. The owner prefers action over repeated permission requests for routine, reversible work.
- Routine commits and pushes are authorized. **Do not publish a release, push a version tag, dispatch the Release workflow, or bump versions merely because a change is complete. Release only when the owner explicitly asks.** Normal main pushes run CI only.
- Preserve unrelated working-tree changes. Inspect the current status before editing or committing.
- Keep communication concise and concrete. Explain results and verification limits without presenting untested behavior as verified.
- Do not add AI functionality unless requested. Do not add UI copy, onboarding steps, dialogs, or status indicators merely to explain implementation details.
- Do not use real writing as test content. Create disposable workspaces under ignored `build/`, and restore the original workspace after UI tests.

## Roadmap and backlog maintenance

- `ROADMAP.md` is the canonical backlog for features, ideas, fixes, and open questions. Read it before planning or implementing product work.
- When the owner asks to save an idea or document a follow-up, add or update an entry there in the same turn. Capture intent without treating it as permission to implement.
- Keep stable item IDs; update existing entries rather than duplicating them. Distinguish agreed plans, uncommitted ideas, confirmed bugs, and verification gaps.
- When building, mark the relevant item In progress, then update its outcome and verification when finished. Split remaining work into explicit follow-ups; record blockers and dropped decisions with reasons.
- Keep the last-updated date current when editing the backlog. Update detailed design/verification documents when needed and link them from the roadmap; avoid competing task lists.
- Do not leave completed work marked pending or mark an entire feature Done when only part of its scope was delivered. Completing backlog work does not authorize a release.

## User-facing wording

Owner's rule (2026-11-22) for every user-facing string: the Mac and iPhone apps, MatildeKit copy, the website (including privacy), release notes and user-facing docs.

- Don't name the developer in the apps. Nothing "goes to Filip" or "goes straight to Filip"; feedback copy says what's included, not who reads it. The website's footer credit "Built by Filip" (linking to tsolov.zip) stays; avoid other mentions of him.
- No company or developer voice in privacy copy: no "we can't read", "by us", "not even us", "we see your email". Centre on the person and on what the system does: "Encrypted on your devices. No one else can read your notes." or "The server sees your email address, never what you write."
- Code identifiers, git history and internal docs (ROADMAP, AGENTS, docs for the owner) are exempt.

## Visual and interaction direction

- SwiftUI app with native macOS controls. Bear is the closest writing reference; Obsidian, Raycast Notes, and Notion are secondary references. The sidebar takes inspiration from Linear.
- Japanese paper feeling: warm ivory, muted olive-gray text, restrained brown accents, tactile details, generous writing space. Keep navigation compact and quiet.
- Bundled **Newsreader** Roman and Italic variable fonts for document titles, writing, and Markdown headings. Use system typography for controls. Font files and the SIL Open Font License are in `Sources/Matilde/Resources/Fonts/`; no runtime font download.
- Interface icons are Tabler Icons (outline, redrawn at a 1.5 stroke; filled only for state or solid composer actions), all named in the `MatildeIcon` enum. Use `MatildeIcon.x.image(size:)`/`nsImage(size:)` rather than `Image(systemName:)`; SF Symbols remain only on native menu items. To add or change an icon, edit the enum's raw value and run `python3 scripts/tabler-icons.py` (pinned Tabler release, needs `cairosvg`), then commit the SVG and generated PDF.
- The sidebar shows one two-line row per draft family: the family title with a quiet branch icon and alternate-draft count, above the main document's goal (or “No goal set”) and a 12-point relative edited timestamp. Branches have no rows of their own; the draft switcher above the title and the board choose between them. Folder controls remain compact, with an 18-point icon column, subtle hover/selection, a hover `+` that creates a note in that folder, and collapsible folders. Folder expansion is currently session-only. The sidebar has no title header: a permanent search field sits at the top; the workspace dropdown was deliberately removed. Notes move between folders by dragging rows onto folders (`NoteMove.swift`); moves keep draft IDs/metadata, never overwrite files and copy referenced `.assets` images. Scrollbars are hidden everywhere; keep new scroll views indicator-free.
- Markdown renders live, with syntax concealed during normal editing. The owner explicitly dislikes Bear's visible formatting symbols. Preserve the underlying Markdown losslessly.
- New Document creates a unique `Untitled.md` immediately, with no dialog. Focus the inline title, styled as a heading. The optional goal sits underneath as paragraph text with a flag icon. Both remain editable; changing the title renames the file without overwriting existing files.
- Title, goal, and draft controls scroll with the body in one native scroll view. Restore the saved scroll offset. There is no window top bar (UI-20): the title bar is hidden, the traffic lights float over the sidebar beside the sidebar toggle, and document actions float at the canvas's top-right and fade out while typing. The SwiftUI header is hosted inside the AppKit writing view and exposed as an accessibility child.
- Draft count/switcher and branch button sit **above the title**, with breathing room. Long titles wrap; they must not be clipped by controls.
- Successful saves stay silent. The save indicator and word counter were deliberately removed; do not restore them unasked.
- Motion should feel tactile but snappy. Respect Reduce Motion and keep typing/focus reliable.

## Repository layout

A monorepo. Paths in the sections below are relative to `apps/macos/` unless they start with `docs/`, `server/`, `packages/`, `apps/ios/`, `ROADMAP.md` or `.github/`.

| Path | Contents |
| --- | --- |
| `apps/macos/` | The macOS app: `Package.swift`/`Package.resolved`, `Sources/`, `Tests/`, `assets/` (icon sources), `Config/release.json`, `release-notes/`, and its build, packaging and release scripts in `scripts/` (with `scripts/tests/`) |
| `apps/web/` | Landing page (matilde.page): Astro site on a Cloudflare Worker, see `apps/web/README.md` |
| `apps/ios/` | The iOS app: SwiftUI, iOS 26, iPhone first; notes library, editor, comments, Ask Matilde threads and sync on MatildeKit; XcodeGen `project.yml` (the `.xcodeproj` is generated, not committed), see `apps/ios/README.md` |
| `packages/MatildeKit/` | Shared Swift package used by the macOS and iOS apps: sync records, sync engine, HTTPS transport and end-to-end encryption, plus `MatildeKitTesting` (fake sync server). Builds and tests on Linux too (swift-crypto stands in for CryptoKit); see `packages/MatildeKit/README.md` |
| `server/` | Cloud sync server (Cloudflare Worker), deployed by `.github/workflows/server.yml` |
| `docs/` | Product, architecture, sync and release documentation, verification log; `docs/sync-vectors/` are shared crypto test vectors for every client |
| `scripts/` | Repo-wide scripts only (`sync-vectors.py`, which regenerates `docs/sync-vectors/`) |
| `ROADMAP.md` | Backlog for the whole product |
| `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml` | pnpm workspace for the JavaScript packages (`apps/web`, `server`): one root lockfile, pnpm version pinned in `packageManager`. Use `pnpm install` / `pnpm run` / `pnpm exec`, never npm; `corepack enable` once installs pnpm |

CI (`.github/workflows/ci.yml`) runs the macOS job (app and MatildeKit tests) only when `apps/macos/`, `packages/`, `docs/sync-vectors/` or the CI/Release workflows change; the iOS job (macos-26, XcodeGen, iPhone simulator tests) when `apps/ios/`, `packages/`, `docs/sync-vectors/` or `ci.yml` change; the Linux `kit` job (MatildeKit `swift test`) when `packages/`, `docs/sync-vectors/` or `ci.yml` change; its `required` job always reports and is the check to require. `server.yml` and the web workflow have their own path filters.

## Stack and source map

This is a Swift Package Manager project, not an Xcode project. `Package.swift` uses Swift tools 6 with Swift 5 language mode, a macOS 14 minimum, system SQLite, and a pinned Sparkle dependency. Consult the manifest for current versions.

| File | Responsibility |
| --- | --- |
| `Sources/Matilde/MatildeApp.swift` | App lifecycle, menus/toolbars, sidebar, inline title/goal, writing layout, editor/board transition orchestration |
| `Sources/Matilde/AppModel.swift` | Workspace and draft state, autosave, selection, external reload, branching/removal, board navigation and editor readiness |
| `packages/MatildeKit/Sources/MatildeKit/Storage/Workspace.swift` | Markdown file operations, SQLite metadata, snapshots, draft relationships, session state, Trash behavior |
| `packages/MatildeKit/Sources/MatildeKit/Storage/WorkspaceStore.swift` | Workspace ID, database location in Application Support and the one-time migration out of `.matilde` (SYNC-01) |
| `packages/MatildeKit/Sources/MatildeKit/Storage/` (rest), `Review/`, `Assist/` | Shared with iOS since IOS-02: trash, sidebar order, note moves, stash storage and welcome document; review data (`UserComment`, `WritingReview`, `ReviewTracking`, `ThreadTimeline`); Ask Matilde client (`LangdockClient`, prompts, `APIKeyStore`, `WritingReviewModel`). The macOS files with the same names keep only the AppKit/SwiftUI parts |
| `packages/MatildeKit/Sources/MatildeKit/Records/` (`SyncRecord.swift`, `SyncPayloads.swift`), `packages/MatildeKit/Sources/MatildeKit/Storage/SyncLedger.swift` | Portable sync records (SYNC-02): HLC, record ids, canonical fields; change tracking, tombstones and outbox in `sync_records` (all in MatildeKit since IOS-02); contract in `docs/sync-model.md` |
| `Sources/Matilde/MarkdownEditor.swift` | AppKit text view embedded in SwiftUI, Markdown styling/concealment, formatting commands, list behavior, cursor/scroll restoration |
| `Sources/Matilde/DraftComparison.swift` | Independent editable comparison buffer, autosave/recovery and native split pane |
| `packages/MatildeKit/Sources/MatildeKit/Storage/BoardStore.swift` | Persisted sheet placement and family viewport storage |
| `Sources/Matilde/DraftBoard.swift` | Pinned draft canvas, shared page previews, mounted editor surface, pan/zoom, hover/cursors, keyboard navigation |
| `Sources/Matilde/DraftInteraction.swift` | Branch preview tray and in-memory page capture used for the curl |
| `Sources/Matilde/PageCurlView.swift` | SceneKit page mesh, materials, and diagonal branch animation |
| `Sources/Matilde/AppIcon.swift` | App icon choices, stored preference, runtime Dock icon and the Settings picker; SVG sources in `assets/app-icons`, PNGs from `scripts/app-icons.py` |
| `Sources/Matilde/MatildeIcon.swift` | Tabler icon names, template image loading and sizes; PDFs in `Resources/Icons`, source SVGs in `assets/tabler-icons` |
| `Sources/Matilde/AppUpdater.swift` | Sparkle controller and native Check for Updates action |
| `packages/MatildeKit/Sources/MatildeKit/Sync/`, `Sources/Matilde/Sync/` | Client sync (SYNC-07): in MatildeKit the `SyncEngine` push/pull actor, `SyncMerge` rules, `SyncCodec` framing, `SyncWire` and `HTTPSyncTransport` (sessions, Keychain tokens, WebSocket); `WorkspaceSyncStore` mirror into files and tables (MatildeKit since IOS-02); in the app the `SyncCenter` controller and the Settings → Sync tab; see `docs/sync-client.md` |
| `packages/MatildeKit/Sources/MatildeKit/SyncCrypto/` | End-to-end encryption for cloud sync (SYNC-06): account key ring, record/blob/field envelopes, recovery key, key slots, Keychain store; spec in `docs/sync-encryption.md` |
| `Tests/MatildeTests/` | Workspace, Markdown, curl geometry, and native editor regression tests |
| `packages/MatildeKit/Tests/MatildeKitTests/` | Sync record, engine, transport, crypto, recovery and shared-vector tests (run on macOS and Linux) |
| `Config/release.json` | Local version, stable bundle identifier, repository, update URL and public signing key |
| `server/` | Cloud sync server (TypeScript Cloudflare Worker, Durable Objects, D1, R2); its own README, PROTOCOL.md and vitest suite (`cd server && pnpm install && pnpm test`, runs on Linux) |
| `server/src/mcp/`, `packages/MatildeKit/Sources/MatildeKit/Sync/ConnectedAITools.swift` | Remote MCP server for AI tools (AI-18) on the MCP host of the sync Worker: OAuth, consent page, tools, grants and audit; the apps' Connected AI tools list; see `docs/mcp.md` |
| `scripts/` (plus `.github/workflows/` at the repo root) | App assembly, tests, signing, packaging, release validation and publication |

## Files, persistence, and data safety

- Manage one workspace folder, with subfolders. First launch offers Start writing, creating/reusing `~/Documents/Matilde`; choosing another folder is secondary. Never replace existing workspace files.
- Writing lives in ordinary `.md` files. The workspace database (goals, draft identity/relationships, state, Ask Matilde history and private user comments: `user_comments`, anchored by UTF-16 range plus quote/context; never written into Markdown) lives **outside the workspace** in `~/Library/Application Support/Matilde/workspaces/<workspaceID>/workspace.sqlite` (SYNC-01), because the workspace may sit in iCloud Drive or Dropbox, which can corrupt a live SQLite file. `workspaceID` is in `.matilde/workspace.json`; `WorkspaceStore.swift` resolves the store, tells moved from copied workspaces apart and migrates an old `.matilde/workspace.sqlite` once (verified SQLite backup, atomic rename, old file renamed to `workspace.sqlite.migrated`, never deleted). Never put a live database back inside the workspace. Tests get a temporary store (`MATILDE_STORE_DIRECTORY` overrides it). `.matilde/snapshots` holds immutable branching snapshots and stays in the workspace; backing up the workspace no longer includes the database.
- Sync records (SYNC-02, `docs/sync-model.md`): `sync_records`/`sync_meta` in the workspace database track every synced entity's HLC, tombstone and pending state; `trackSyncChanges()` runs on open and quit and only reads the app's tables and files. Keep new synced data inside a record type, keep device-local state (cursor, scroll, board, comparison, window) out of records, and never tombstone a file that is merely missing or evicted.
- Cloud sync (SYNC-07, `docs/sync-client.md`) is opt-in in Settings → Sync and runs off the main thread with its own `Workspace` connection. The mirror only overwrites a `.md` or stash file that is unchanged since the ledger last saw it, sends remote deletions to the Trash, and never logs content, paths, emails, codes or keys.
- Restore workspace, active draft, cursor, scroll, and sidebar/focus state at launch. Switching notes or drafts lands at the top with the caret at the body start (owner's choice); only a new branch keeps its inherited position. Canvas viewport persists per family, but app startup currently opens the editor rather than restoring board mode.
- Autosave is currently debounced about 650 ms. Flush on switching, explicit Command-S, and quitting. Preserve this protection when changing navigation or updater behavior.
- External file edits reload automatically, with existing recovery handling for dirty text. Advanced conflict resolution and identity preservation across external moves remain follow-ups.
- Branching snapshots the source, creates a separate uniquely named Markdown file beside it, inherits the goal and writing position, and opens the child. Both drafts remain editable; a snapshot is distinct from either live draft.
- Move to Trash is available in the document menu and sidebar, tray, and canvas context menus. It moves only the selected Markdown file to native macOS Trash. Children survive and reconnect to the removed parent's parent; removing a family root leaves children as roots in the same family.
- Removed metadata is archived in `trashed_drafts`; snapshots remain. A failed filesystem move rolls back metadata changes. Restoring a file from Trash currently imports it as a new draft; automatic recovery of its archived goal/family/position is not implemented.
- Preserve filename collision checks, workspace boundary/symlink protections, and database transaction behavior. Do not replace Trash with permanent deletion.
- Command-Delete trashes the active file only when the sidebar document list owns native keyboard focus. Sidebar clicks keep focus there across draft loading; editor/title/goal/search inputs retain native text deletion. Never make file deletion an unconditional global shortcut. `SidebarKeyboardInput.swift` owns this routing.

## Editor invariants and pitfalls

- Supported scope: headings, emphasis, links, lists, checklists, blockquotes, dividers, fenced code, and standalone local Markdown images. The small Markdown renderer is not a complete CommonMark parser. Tables and remote image fetching are deferred.
- Empty workspaces receive a welcome document once, with a sample goal. Help can reopen or explicitly recreate it; never overwrite edited welcome content or reseed after deletion automatically.
- Image paste/drop stores immutable PNG files in `.assets` beside the draft, using relative Markdown references shared by branches. Do not delete assets on undo or draft Trash because other drafts/snapshots may reference them. Images are limited to 32 MB input and 40 megapixels; automatic unused-asset cleanup is not implemented. Bare URLs auto-link, pasting a URL over text creates a Markdown link, and Command-K adds/edits links.
- Side-by-side comparison uses an independent DraftComparison session, flushed on close/switch/quit. MarkdownEditor coordinators own separate undo managers; never fall back to a shared window undo history across panes. Comparison selection, divider proportion and difference visibility persist per workspace. Difference highlighting is display-only; keep both undo histories independent.
- Styling must not rewrite the source text. Keep UTF-16 `NSRange` handling correct for Unicode and preserve native selection and undo behavior.
- Command-B/Command-I toggle formatting, including nested emphasis. List continuation resets task checkboxes, exits empty lists, respects code fences, and handles numeric overflow.
- Checklist clicks must hit the actual glyph, not nearby whitespace or an active text selection.
- An editor already on screen lands synchronously on a draft switch (layout and scroll before the next draw); only the first mount waits for SwiftUI sizing before restoring. Generation guards cancel stale restoration. Typing during initial layout must be saved immediately; never leave change reporting disabled during the delay.
- Canvas opening waits for the destination editor to be ready. Avoid races between draft identity, text loading, restored position, and animation completion.

## Branching and canvas

- Branch animation is inspired by Apple Books on iPad: a 3D curl **from bottom-right toward top-left**, paper underside, text show-through, and moving shadow. It lasts about one second; Reduce Motion skips it.
- The canvas shows the current draft family, not every workspace document. Related sheets have persisted automatic positions and subtle connectors.
- Command-0, the toolbar board control, or a deliberate editor pinch opens the board. Editor pinch continuously drives the mounted page with a 3% dead zone and cubic ease-out; corners round into the board's 16-point card radius. Release at 18% outward travel settles onto the board; reversal/cancellation returns to writing. Native event capture lasts through gesture end. Physical trackpad verification remains CAN-07.
- Drag empty board space, two-finger scroll, or mouse wheel to pan. Pinch and +/- zoom; Fit frames the family. Arrow keys select, Return opens, Escape returns to the active draft. An inward pinch ending above 120% opens the sheet under the pointer at gesture start, with pointer-anchored zoom. Pinching empty space never falls back to the active draft.
- Pages lift subtly on hover and show a pointing-hand cursor. Keep hover/context-menu modifiers scoped to the sheet before positioning; attaching them to a large positioned container previously caused oversized hit regions.
- Editor/board transitions keep the real editor mounted at its full layout size, animate scale/clipping, and blend into the same preview used by the board. Current flights last 340 ms with animation-completion callbacks.
- Do not reintroduce screenshot swapping, approximate replacement editors, fixed completion timers, or layout reflow during board flights. In-memory capture remains appropriate for the separate branch curl.
- Future refinements: physical trackpad/resistance verification, dragging/re-pinning individual sheets, large-family usability, and stronger spatial connection between the curl and board placement.

## AI: Ask Matilde

The owner authorized Langdock reviews, replies and automatic review. See `docs/langdock-integration.md` and ROADMAP.md for current scope and verification gaps.

- Keep AI quiet and optional: automatic reviews follow meaningful edits plus thirty seconds idle, with persistent pause/resume in the Ask Matilde toolbar menu. Never send on opening a draft alone.
- Requests supply the active title, goal and body; replies additionally include the relevant thread. Exclude stash, other drafts and image files; preserve image/path scrubbing and Keychain credential storage.
- User-visible name is "Ask Matilde" (internal identifiers and UserDefaults keys keep `writingAssist`). Review/Cancel, pause/resume and history live in one window-toolbar control; the side pane shows only comment cards and threads.
- AI and private comments stay on their passages (`CommentAnchor`, shared via `AnchoredPassage`): edits before shift them, edits inside grow/shrink them, partial deletion shrinks them to what remains. They disappear only when the entire passage is deleted (AI status `removed`, user comment detached; undo restores both) or when archived explicitly (archive icon at the card’s top right on hover or while open, and in the comment popover). Archiving an Ask Matilde thread marks it `dismissed` (still in Review history); archiving a private comment sets `user_comments.archived = 1` (kept in the database, no longer loaded). Title/goal edits never hide comments. A rewrite applies only while its passage is unchanged (`rewriteQuote`). Edits and switches still cancel pending requests and discard late responses.
- Selection help uses the floating Ask Matilde action, context menu and Shift-Command-A. Without a selection the shortcut uses the current paragraph (trimmed); on an empty line it reviews the draft. It creates an exact anchored thread and focuses the composer without sending until submission. Messages persist optimistically with pending/sent/failed state; cancellation and retries must preserve questions without duplication.
- Editor text changes: never force glyph generation, layout or geometry queries while the text storage is editing (`WritingTextView.isStorageEditing`). Autocorrection can report a change inside AppKit's editing batch; `Coordinator.textDidChange` and the slash menu defer to the next run-loop turn then (regression: `SpellCheckingTests`). Spelling/grammar markers are drawn by `WritingLayoutManager` just under the baseline; AppKit's own markers are hidden during glyph drawing because it places them at the bottom of the line spacing.
- Private comments use Add Comment (Shift-Command-K, context menu): selection, else the current trimmed paragraph; on an existing comment it reopens it. Comments are always visible: Ask Matilde threads and private comments share one right-margin column (`MarginItem` in `WritingReview.swift`); `CommentMargin.layout` (`WritingReview.swift`, used by `CommentMarginColumn` in `MatildeApp.swift`) centers the text and the 280-point card column as one group with equal outer margins (36-point gap to the text) while comments exist, and centers the text alone otherwise. Ask Matilde passages are marked in the text with a quiet accent underline and faint tint (stronger when hovered or open, `ReviewAnchorProbe`); private comments keep the yellow highlighter, and each card’s quote rule uses the same color. The composer sits alone at the bottom of a card; Accept sits inside the suggested rewrite. Private comments edit inline in their card; only windows too narrow for the gutter fall back to margin icons and popovers. Shared chrome: `PassageQuote`, `composerField`, `PopoverPaperBackground` in `UserComments.swift`.
- Stash opens from the toolbar tray button (or Shift-Command-J); there is no bottom tab, so the margin stays free for cards. The header (draft controls, title, goal) shares the body’s 33-point left edge. Markdown headings use Newsreader at weight 600 and 27/23/21/20/19/19 points, below the 31-point bold title. Branching names count up from the original title (`Workspace.branchBase`), e.g. “Letter — Alternative 2”, never stacking suffixes.
- Settings → Ask Matilde edits only the guidance part of the system prompt; the task, untrusted-writing boundary and JSON response shape in `WritingAssistPrompt.swift` stay fixed and are always appended.
- Persist histories and replies locally; branches start independent histories. Rewrites always require acceptance and native undo.
- Follow-up directions and automatic naming remain separate requested/planned work; do not expand AI scope unasked.

## Development and verification

Run from `apps/macos/`:

```sh
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests
bash scripts/build-app.sh
```

The build script assembles `build/Matilde.app`, bundles fonts, interface icons, app icon and Sparkle, and verifies its code signature. The build always targets arm64 (Apple silicon); packaging rejects Intel or universal Matilde executables. The signed feed must require arm64 so existing Intel installs are not offered incompatible updates. Do not manually reconstruct the bundle when the script suffices.

- Run checks appropriate to the change. Documentation-only work does not require rebuilding the app. For editor/storage changes, run relevant regression tests and the build; for UI changes, inspect the running app as well.
- Use supported computer-use tools for UI testing and restarting. Quit normally so pending writing flushes, then launch the built bundle. Do not force-kill an app holding unsaved writing.
- Use isolated test folders under `build/`. Do not type into the owner's documents or reset the real workspace database/preferences to simplify tests.
- In the Codex filesystem sandbox, macOS pasteboard tests can fail because pasteboard access is denied, and `iconutil` can misleadingly report Invalid Iconset. If needed, rerun the same authorized checks with escalated permissions rather than altering working production code to accommodate the sandbox.
- Swift module caches can be redirected to `.build/clang-cache` and `.build/module-cache` if necessary. GitHub access may likewise need network escalation; do not assume a sandbox authentication failure means credentials are invalid.
- CUA text selection/caret placement can be inaccurate in rendered Markdown. Confirm actual selection before typing; an automation failure alone is not proof of an editor bug.
- At this handoff, 24 Swift tests and 2 Python release tests passed. Treat this as historical evidence, not a substitute for verifying later changes.
- `.build/` and `build/` are ignored generated outputs. Avoid committing test workspaces, bundles, caches, credentials, or local artifacts.

## GitHub distribution and updater

- Public source repository: `https://github.com/gontsolov/matilde`, default branch `main`. The owner explicitly chose public source and direct GitHub distribution, not the Mac App Store.
- Main pushes and pull requests run CI. A `v*` tag or manual Release workflow publishes a version. **Only trigger publication on an explicit release request.**
- Release configuration and scripts are authoritative for the current version; do not hardcode a latest version in future instructions.
- Release pipeline validates increasing versions and main ancestry, tests, builds the arm64 binary, packages a DMG, signs the archive/feed, uploads assets to a draft release, then publishes it as latest.
- Stable download: `https://github.com/gontsolov/matilde/releases/latest/download/Matilde.dmg`.
- Stable Sparkle feed: `https://github.com/gontsolov/matilde/releases/latest/download/appcast.xml`.
- Sparkle verifies signed updates before extraction and uses native install/relaunch UI. Automatic installation and system-profile submission are disabled. Preserve save-on-quit behavior.
- Keep the existing bundle identifier `app.matilde.local` and signing identity stable unless a deliberate migration is requested.
- Sparkle private key is in the local login Keychain under account `app.matilde.local` and configured in GitHub Actions as `SPARKLE_PRIVATE_KEY`. Its initial transfer was owner-authorized and completed. Never regenerate it per release, print/export it into logs, or commit it. The public key in configuration is safe to commit.
- Current distribution uses ad-hoc code signing, **not Developer ID signing or Apple notarization**. Sparkle authentication does not remove first-launch Gatekeeper restrictions. Do not claim fully secure or notarized distribution.
- The optional Apple certificate/notarization workflow exists but has not been verified with real credentials. An App Store submission is not needed for Developer ID direct distribution.
- Signed archive/feed verification and a real Sparkle install/relaunch from an artificially older disposable app copy have passed. First launch of a quarantined download on a clean Mac remains unverified.
- Do not edit a generated appcast after signing. If raising the minimum macOS version, preserve compatible older feed entries. Keep Actions pinned and signing secrets out of untrusted PR workflows.

## Further context

- `docs/architecture.md`: product decisions and AI design history.
- `docs/langdock-integration.md`: Ask Matilde behavior, context boundary and verification.
- `docs/mcp.md`: the remote MCP server for AI tools (AI-18), its trade-off, OAuth, scopes and setup.
- `docs/stash.md`: stash design and refinements.
- `docs/canvas-followup.md`: implemented canvas behavior and remaining interaction work.
- `docs/releases.md`: release commands, signing setup, optional notarization, and verification.
- `docs/verification.md`: chronological checks, fixes, and limitations.

Some older sections record historical scope (for example, canvas/distribution deferrals or old test counts). Read later updates and current code before treating them as current restrictions. Update relevant documentation when behavior or decisions change, and keep this handoff focused on durable context rather than session logs.
