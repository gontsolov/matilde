# Matilde roadmap

Our living backlog for features, ideas, fixes, and open questions. Save new ideas here; update entries as we build. Product direction: a quiet native writing experience, tactile drafts on a canvas, and AI as a supporting feature.

Last updated: 2026-09-14.

## How we use this

- “Save this idea”, “later”, and “document as a follow-up” mean capture it here, not start building it.
- Give each item a stable ID, a status, and a concrete outcome. Keep the user's intent and link to detailed design notes when useful.
- Statuses: **Idea** (uncommitted), **Planned** (agreed direction), **In progress**, **Blocked** (state the dependency), **Done**, or **Dropped** (keep the reason).
- Before building, review this backlog and update the relevant item. Record newly discovered fixes and questions without presenting unverified concerns as confirmed bugs.
- After building, record what works and how it was checked. Mark Done only when the stated scope is complete; keep unfinished parts as separate entries.
- Priority/order is provisional until we choose the next task. Saving or completing an item does not authorize a release.

## In progress

No implementation currently in progress.

## Writing quality and fixes to investigate

These are known limitations or verification gaps, not claims that every case is broken.

| ID | Status | Item and completion criteria |
| --- | --- | --- |
| EDIT-06 | Planned | **Confirm cursor artifact is resolved.** User reported tiny chevrons at the typing cursor. Removed the 8-point blank-line font, a likely cause of a shrunken caret; exact reported artifact has not been reproduced. Follow up if it persists. |
| EDIT-08 | Done | **Top-anchored wrapping header.** Measure the header at the actual editor width so longer titles grow downward, retaining the draft controls' top position and pushing the goal/body down. All 36 tests and app build/signature checks pass. Compared the owner's one-line and two-line examples live without editing writing; top alignment stays fixed and body moves down. |
| EDIT-09 | Done | **Quiet spelling.** Automatic red spelling underlines are disabled in the writing editor; native right-click spelling tools remain available. All 36 tests and app build/signature checks pass; clean editor and spelling context menu inspected live without changing writing. |
| ONB-01 | Done | **Welcome document.** An editable concise introduction seeds once in an empty workspace, with a sample goal and invitation to branch. Help reopens/recreates it without overwriting writing. One-time seeding, existing writing, edited welcome preservation, and explicit recovery tested; first-launch page inspected live in an isolated workspace. |
| EDIT-11 | Done | **Images and links.** Local image paste/drop and inline rendering with relative `.assets` references; bare URL auto-linking, URL-over-selection, and Command-K link editing. All 45 tests and app build/signature checks pass. Live checks cover image clipboard paste, undo/redo, branching/reopen, layout, URL paste and link editing. Remaining drag/large-image checks are EDIT-12. |
| EDIT-12 | Planned | **Media follow-up verification.** Exercise Finder file paste/drop end-to-end, image-heavy document performance, resizing with many images, and external asset replacement. Current native clipboard image paste is verified. Remote image fetching, rich URL cards, image-specific selection/resize controls, and automatic unused-asset cleanup remain outside delivered scope. |
| EDIT-10 | Done | **Markdown divider.** A standalone `---` renders as a thin muted line across the writing column, preserving source and ordinary caret metrics. Inline/code dashes remain literal. All 38 tests and app build/signature checks pass, including Unicode/lossless styling, removing divider syntax, Return, and undo. Inspected the owner's existing divider live without editing writing. |
| EDIT-01 | Planned | **Markdown boundary behavior.** Verify caret movement, selection, deletion, and unfinished/nested formatting across hidden syntax, including Unicode. Fix reproducible failures while preserving source text and native undo. Existing formatting toggle fixes are complete; this is broader coverage. |
| EDIT-02 | Planned | **Long-document performance.** Measure typing, styling, scrolling, and draft switching with large documents. Record realistic fixtures and results; fix observed stalls rather than assuming a performance problem. |
| DATA-01 | Idea | **Restore draft metadata from Trash.** Reconnect a restored file to its archived goal, family, and writing position. Today restoring Markdown imports it as a new draft. Decide how identity is matched safely before implementing. |
| DATA-02 | Idea | **External moves and renames.** Preserve document identity and branch metadata when files move outside Matilde. Today external moves do not automatically preserve identity. |
| DATA-03 | Idea | **Recovery and overlapping external edits.** Review file/database failure recovery and define behavior when external changes overlap unsaved writing. Preserve the agreed simple reload experience; advanced conflict UI is deferred. |

## Canvas and draft interaction

Detailed interaction notes: [canvas follow-up](docs/canvas-followup.md).

| ID | Status | Item and completion criteria |
| --- | --- | --- |
| CAN-01 | Done | **Continuous zoom with resistance.** Editor pinch drives the mounted page continuously with a 3% dead zone and quadratic resistance. Release at 18% outward travel settles onto the board; reversal or cancellation settles into writing. Reduce Motion skips scaling. Build/signature verification and 27 tests pass; keyboard round trips, resumed typing, branching, and opening another sheet verified live. Physical trackpad verification remains CAN-07. |
| CAN-07 | Planned | **Physical trackpad verification.** Verify CAN-01 on a real trackpad: short/reversed/cancelled pinches, sustained finger tracking, release into the board, return to typing, and Reduce Motion. Tune resistance if needed. Native UI automation does not expose pinch gestures; current automated checks cover the curve and release decision, not end-to-end native gesture delivery. |
| CAN-08 | Done | **Zoom feel and pointer targeting.** Replaced CAN-01's quadratic curve with cubic ease-out after the dead zone. Sheet corners round during the flight and match the rounded board cards. Board pinch captures the page and anchor under the pointer at gesture start; empty space never falls back to the previous draft. All 31 tests and app build/signature checks pass; rounded pages and keyboard round trip inspected live. Physical pinch verification remains CAN-07. |
| CAN-02 | Idea | **Drag and re-pin sheets.** Move individual drafts independently of board panning, persist positions, and keep connectors correct. Placement is currently automatic. |
| CAN-09 | Done | **Dotted canvas.** Visible muted dot grid behind sheets, matching the supplied reference: 20-point spacing, 1.6-point dots, and 25% ink opacity. Spacing stays consistent on screen and the pattern shifts with panning. App build/signature checks passed; appearance and panning inspected live in a disposable workspace. |
| CAN-10 | Done | **Clean canvas previews.** Show title and body excerpt without the goal or flag; retain the editable goal and its saved value in the editor. App build/signature checks and live verification with a populated disposable goal passed. See [verification](docs/verification.md). |
| CAN-11 | Done | **Clamp document zoom-out speed.** Owner found the initial cap too slow. Retuned tracking to 5/sec with 60 ms smoothing and shortened outward settle to 180–420 ms (previously up to 1500 ms); delayed-frame protection remains. All 35 tests and app build/signature checks pass; canvas/editor round trip checked live without editing writing. Physical pinch feel remains CAN-07. |
| CAN-03 | Planned | **Large-family usability.** Check navigation, preview readability, frame rate, and spatial orientation with many branches. Keep offscreen previews lightweight and tune based on measured issues. |
| CAN-04 | Idea | **Connect the page curl to the board.** Make the bottom-right-to-top-left curl communicate where the previous draft lives on the canvas, while making clear both drafts remain editable. Explore the motion before committing to an implementation. |
| CAN-05 | Idea | **Restore board mode on launch.** Decide whether reopening should return to the canvas when that was the last view. Currently the viewport persists but startup opens the editor. |
| CAN-06 | Idea | **Hold-and-release draft switching.** Explore a fast keyboard interaction for the excerpt tray. Current arrow/Return/Escape navigation remains the baseline. |

## Later: quiet AI assistance

Explicitly deferred; recording these does not authorize implementation. See [architecture notes](docs/architecture.md) for context.

| ID | Status | Item and completion criteria |
| --- | --- | --- |
| AI-01 | Planned | **Langdock foundation.** Investigate the API, store the user's key appropriately, and define exactly what document context is sent. Use the editable writing goal. Resolve privacy and credential behavior before integration. |
| AI-02 | Planned | **Review comments.** Quiet margin threads after meaningful edits and roughly 30 seconds of inactivity, plus pause and Review now. Support replies, acceptance, removal, and local history. Define anchors, stale review handling, and branch history semantics first; never apply edits without acceptance. Depends on AI-01. |
| AI-03 | Planned | **Follow-up directions.** Suggest ways to continue or explore a text without interrupting writing. Exact presentation remains open. Depends on AI-01. |
| AI-04 | Planned | **Automatic naming and renaming.** Offer useful document/draft names with user control and safe filename collision handling. Triggers and controls remain open. Depends on AI-01. |

## Distribution and other ideas

| ID | Status | Item and completion criteria |
| --- | --- | --- |
| DIST-01 | Planned | **Clean-Mac installation verification.** Test a quarantined public download on a clean Mac and document first-launch behavior. Signed updater installation has been tested; this specific first-install scenario has not. |
| DIST-02 | Idea | **Developer ID signing and notarization.** Optional direct-distribution improvement, not an App Store submission. Requires owner-provided membership/certificate credentials; verify the existing optional workflow with real credentials before claiming support. Current releases are ad-hoc signed and not notarized. |
| EDIT-03 | Idea | **Tables.** Deferred beyond the initial Markdown scope. Local embedded images were delivered in EDIT-11; table editing still needs design. |
| UI-01 | Idea | **Persist folder expansion.** Consider restoring collapsed sidebar folders between launches; currently session-only. |
| UI-05 | Planned | **Settings foundation (later).** A native macOS Settings window, opened with Command-comma, to house customization and future API-key management. Candidate controls: writing size/line spacing, appearance, spelling, and canvas/motion preferences; exact controls remain uncommitted. Store credentials in macOS Keychain, never workspace files or logs, with masked entry and replacement/removal. Coordinate provider settings with AI-01; this does not authorize AI integration or implementation now. |
| UI-04 | Done | **Sidebar Command-Delete.** Clicking the document list gives it native keyboard focus; Command-Delete moves the active file to native Trash only while that responder owns focus. Repeated key events are ignored. Text inputs retain native deletion. All 32 tests and app build pass; sidebar Trash, editor deletion/undo, and search deletion verified live with disposable files. |

## Completed foundation

These summarize implemented scope, not a claim that all possible edge cases are verified. Historical verification is in [verification notes](docs/verification.md).

| ID | Status | Delivered |
| --- | --- | --- |
| EDIT-07 | Done | Return in the goal saves and focuses the body; Shift-Return is passed through. Built and verified live that focus moves from Writing goal to Writing editor without altering text. |
| UI-03 | Done | Title, goal, and draft controls scroll with the body; a compact native toolbar title with 16-point horizontal padding appears after the header leaves view. Verified scrolling both ways and reopening at the saved offset; 24 tests and build pass. |
| UI-02 | Done | Removed the sidebar workspace switcher; the header is a plain Matilde label beside search. |
| EDIT-05 | Done | Quote rule uses text baseline/font metrics instead of the line box; blank lines retain normal font and caret height. Build and 24 tests passed; quote inspected after restart. |
| EDIT-04 | Done | Quotes use a muted vertical rule and normal ink; paragraphs have more spacing, blank source lines are compact, and lists have tighter rows with muted bullets/numbers. Build and 24 tests passed; quote alignment and numbered lists inspected in the live app. |
| BASE-01 | Done | Native SwiftUI/AppKit writing app, one local folder, ordinary Markdown files, SQLite metadata, default workspace creation, and session restoration. |
| BASE-02 | Done | Live Markdown styling; bundled Newsreader; immediate new documents with inline title and optional flag-marked goal; compact sidebar; silent autosave without word count or saved indicator. |
| BASE-03 | Done | Independent branches with immutable divergence snapshots, inherited goal/position, draft excerpt switcher, and diagonal SceneKit page curl. |
| BASE-04 | Done | Family canvas with pinned previews, persisted placement/viewport, panning, zoom, hover/pointer effects, keyboard navigation, and mounted-editor transitions. Further refinements remain above. |
| BASE-05 | Done | Move to Trash from document/sidebar/tray/canvas; children survive and metadata is archived. Automatic metadata restoration remains DATA-01. |
| BASE-06 | Done | App icon, public GitHub repository, universal DMG release workflow, signed Sparkle feed/archives, and native update installation. Apple notarization remains separate. |
| BASE-07 | Done | Formatting toggle/undo improvements, list and checklist continuation fixes, fenced-code handling, and save handling during initial layout. Historical check: 24 Swift and 2 Python tests passed. |

## Dropped

None recorded. Keep rejected ideas here with their reason so they are not repeatedly proposed.
