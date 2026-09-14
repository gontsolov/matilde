# Matilde: agent handoff

## Product and collaboration

Matilde (also called Tilde during naming) is a native macOS writing app. The priority is an excellent, quiet writing experience with independently editable alternate drafts. AI will support writing later; it is not the center of the product.

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

## Visual and interaction direction

- SwiftUI app with native macOS controls. Bear is the closest writing reference; Obsidian, Raycast Notes, and Notion are secondary references. The sidebar takes inspiration from Linear.
- Japanese paper feeling: warm ivory, muted olive-gray text, restrained brown accents, tactile details, generous writing space. Keep navigation compact and quiet.
- Bundled **Newsreader** Roman and Italic variable fonts for document titles, writing, and Markdown headings. Use system typography for controls. Font files and the SIL Open Font License are in `Sources/Matilde/Resources/Fonts/`; no runtime font download.
- Use consistent native SF Symbols. There is no need to introduce an external icon library for ordinary controls.
- Sidebar document rows use two lines at approximately 53 points: title above a 12-point relative edited timestamp and optional main-document goal. Document/branch rows have no icons; branches omit goals and use indentation with a subtle continuous vertical guide below the parent. Folder controls remain compact, with an 18-point icon column, subtle hover/selection, expandable search, and collapsible folders. Folder expansion is currently session-only. The sidebar header is a plain Matilde label; the workspace dropdown was deliberately removed.
- Markdown renders live, with syntax concealed during normal editing. The owner explicitly dislikes Bear's visible formatting symbols. Preserve the underlying Markdown losslessly.
- New Document creates a unique `Untitled.md` immediately, with no dialog. Focus the inline title, styled as a heading. The optional goal sits underneath as paragraph text with a flag icon. Both remain editable; changing the title renames the file without overwriting existing files.
- Title, goal, and draft controls scroll with the body in one native scroll view. Show a compact toolbar title after the header leaves view; restore this state from the saved scroll offset. The SwiftUI header is hosted inside the AppKit writing view and exposed as an accessibility child.
- Draft count/switcher and branch button sit **above the title**, with breathing room. Long titles wrap; they must not be clipped by controls.
- Successful saves stay silent. The save indicator and word counter were deliberately removed; do not restore them unasked.
- Motion should feel tactile but snappy. Respect Reduce Motion and keep typing/focus reliable.

## Stack and source map

This is a Swift Package Manager project, not an Xcode project. `Package.swift` uses Swift tools 6 with Swift 5 language mode, a macOS 14 minimum, system SQLite, and a pinned Sparkle dependency. Consult the manifest for current versions.

| File | Responsibility |
| --- | --- |
| `Sources/Matilde/MatildeApp.swift` | App lifecycle, menus/toolbars, sidebar, inline title/goal, writing layout, editor/board transition orchestration |
| `Sources/Matilde/AppModel.swift` | Workspace and draft state, autosave, selection, external reload, branching/removal, board navigation and editor readiness |
| `Sources/Matilde/Workspace.swift` | Markdown file operations, SQLite metadata, snapshots, draft relationships, session state, Trash behavior |
| `Sources/Matilde/MarkdownEditor.swift` | AppKit text view embedded in SwiftUI, Markdown styling/concealment, formatting commands, list behavior, cursor/scroll restoration |
| `Sources/Matilde/BoardStore.swift` | Persisted sheet placement and family viewport storage |
| `Sources/Matilde/DraftBoard.swift` | Pinned draft canvas, shared page previews, mounted editor surface, pan/zoom, hover/cursors, keyboard navigation |
| `Sources/Matilde/DraftInteraction.swift` | Branch preview tray and in-memory page capture used for the curl |
| `Sources/Matilde/PageCurlView.swift` | SceneKit page mesh, materials, and diagonal branch animation |
| `Sources/Matilde/AppUpdater.swift` | Sparkle controller and native Check for Updates action |
| `Tests/MatildeTests/` | Workspace, Markdown, curl geometry, and native editor regression tests |
| `Config/release.json` | Local version, stable bundle identifier, repository, update URL and public signing key |
| `scripts/` and `.github/workflows/` | App assembly, tests, signing, packaging, release validation and publication |

## Files, persistence, and data safety

- Manage one workspace folder, with subfolders. First launch offers Start writing, creating/reusing `~/Documents/Matilde`; choosing another folder is secondary. Never replace existing workspace files.
- Writing lives in ordinary `.md` files. `.matilde/workspace.sqlite` holds goals, draft identity/relationships, and state; `.matilde/snapshots` holds immutable branching snapshots. Backing up the entire workspace preserves these together.
- Restore workspace, active draft, cursor, scroll, and sidebar/focus state. Canvas viewport persists per family, but app startup currently opens the editor rather than restoring board mode.
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
- Styling must not rewrite the source text. Keep UTF-16 `NSRange` handling correct for Unicode and preserve native selection and undo behavior.
- Command-B/Command-I toggle formatting, including nested emphasis. List continuation resets task checkboxes, exits empty lists, respects code fences, and handles numeric overflow.
- Checklist clicks must hit the actual glyph, not nearby whitespace or an active text selection.
- Loading a draft has asynchronous layout/scroll restoration. Generation guards cancel stale restoration. Typing during initial layout must be saved immediately; never leave change reporting disabled during the delay.
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

## AI: documented future scope

Do not implement this without a new request. Planned provider is Langdock with a user API key; integration details still require investigation.

- Supply the editable writing goal as context.
- After meaningful edits and approximately 30 seconds of inactivity, offer quiet Google Docs-style margin comments. Support review, reply, acceptance, removal, pause, and manual Review now.
- Suggest directions for the writing and optional automatic naming/renaming.
- Never apply suggested text changes without acceptance. Persist comments/history locally and keep histories independent across drafts.
- Resolve anchors under edits, stale reviews, acceptance semantics, credentials, and what content leaves the machine before building integration.

## Development and verification

Run from the repository root:

```sh
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests
bash scripts/build-app.sh
```

The build script assembles `build/Matilde.app`, bundles fonts, icon and Sparkle, and verifies its code signature. The build always targets arm64 (Apple silicon); packaging rejects Intel or universal Matilde executables. The signed feed must require arm64 so existing Intel installs are not offered incompatible updates. Do not manually reconstruct the bundle when the script suffices.

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

- `docs/architecture.md`: product decisions and deferred AI design.
- `docs/canvas-followup.md`: implemented canvas behavior and remaining interaction work.
- `docs/releases.md`: release commands, signing setup, optional notarization, and verification.
- `docs/verification.md`: chronological checks, fixes, and limitations.

Some older sections record historical scope (for example, canvas/distribution deferrals or old test counts). Read later updates and current code before treating them as current restrictions. Update relevant documentation when behavior or decisions change, and keep this handoff focused on durable context rather than session logs.
