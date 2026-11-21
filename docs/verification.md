# First writing-loop verification

Verified on macOS 26.6.2, September 13, 2026, using the locally built app and an isolated workspace under `build/VerificationWorkspace`.

## Manual checks

- Created a document with a writing goal using the native app.
- Typed headings, bold, italic, checklists, quotes, links, and fenced code; inspected the rendered editor and the saved Markdown file.
- Confirmed autosave, keyboard bold formatting, and undo.
- Created an automatically named branch, edited it, renamed it, and switched back to confirm the original was unchanged.
- Toggled a checkbox and confirmed the underlying Markdown changed.
- Edited a test file outside Matilde and confirmed automatic reload.
- Restored the active draft and focus mode after quitting and reopening.
- Scrolled a 30-paragraph document, quit, and reopened. The scrollbar restored to the same position (approximately 39%, saved offset 1260 points).

## Fixes from verification

- Explicitly invalidate cached glyphs after styling, so list markers redraw correctly.
- Use a font containing checkbox glyphs.
- Allow the AppKit text view to grow with long documents and update its size after layout.
- Restore scrolling after initial window layout and focus, suppressing temporary position updates during restoration.

## Automated checks

Six XCTest tests pass: branch/snapshot independence and goal persistence; session-state persistence; external imports and workspace boundaries; unique branch filenames; lossless Markdown styling; Unicode and unfinished syntax preservation. Release app build also passes.

## Branch interaction follow-up

Verified the visible branch action and readable excerpt row in the isolated test workspace. The branch opened at the inherited writing position. Right Arrow followed by Return switched back to the original draft and returned focus to the editor. Added a regression test for inherited cursor/scroll values and independent position persistence. The paper-tear animation is implemented; its tactile feel still needs user feedback.

## Remaining limitations

Markdown rendering is a deliberately small parser, not complete CommonMark support. Nested emphasis, syntax-boundary cursor behavior, and very large documents need further work. Word count is approximate and can count checked task markers. Cursor offsets are persisted and tested at the storage level; precise cursor placement across every formatting boundary is not yet verified. External file moves do not preserve document identity automatically. AI and the canvas remain deferred.

## 3D page curl follow-up

Replaced the flat page transition with a SceneKit mesh and separate front/back materials. Ten tests pass, including a new geometry check for an initially flat page, curved geometry with outward normals, and a completed turn entirely outside the writing pane. Release build passes. Live animation verification was blocked because the Mac was locked; verify the fold, underside, shadow, and return to editing after unlocking.

The curl now follows the bottom-right → top-left diagonal. Regression assertions verify that the bottom-right corner lifts and moves up-left before the other right-hand corner.

## Initial canvas

Release build and 12 tests pass. New tests cover stable automatic sheet positions after reopening and adding branches, plus per-family viewport persistence. Live testing of editor/board transitions, trackpad gestures, keyboard opening, and visual layout is pending: the Mac was locked when computer-use verification was attempted. Do not treat those interactions as visually verified yet.


## Continuous canvas transition

- Release build and all 12 tests passed.
- Replaced screenshot/preview swapping and timer completion with one mounted editor surface, a shared board card, and animation completion.
- Live UI checks: editor to board and back at 140%; opening a different draft from the board at 36%; correct destination title and editable body after completion. No document text was changed.
- Scroll panning verified in the live app. Continuous finger-tracked zoom and frame-rate profiling remain follow-ups.

## First public release and updater (0.1.0)

- GitHub CI passed; Release workflow 34778365601 built and published version 0.1.0.
- Unauthenticated downloads from the stable latest URLs succeeded. The downloaded DMG's SHA-256 checksum matched; archive and feed Ed25519 signatures verified against the committed public key. A locally tampered archive was rejected.
- End-to-end Sparkle smoke test: copied the updater-enabled app into `build/updater-test`, changed its bundle version to 0.0.9, and re-signed the disposable copy ad hoc. The native Check for Updates command discovered 0.1.0, downloaded it, offered Install and Relaunch, replaced the test copy, and reopened the current document. The resulting app reports 0.1.0, passes deep signature verification, and contains x86_64 and arm64 slices.
- No document content was edited during the test. Returned to the normal build afterward.
- This verifies update installation from an artificially older development copy. Apple notarization and first launch of a quarantined download on a clean Mac remain unverified; this release is not Developer ID signed or notarized.


## Editor polish (0.1.1)

Added real NSTextView tests for formatting toggles, nested emphasis, Unicode selections, undo/redo after styling, plaintext paste including links, list/task continuation, empty-list exit, fenced code, large list numbers, and typing during initial layout. All 24 tests pass with macOS pasteboard access. The sandbox denies the separate test pasteboard, so that test was also run outside the sandbox.

Live checks in `build/EditorPolishTests`: Command-B toggled Unicode text on/off, Command-Z and Shift-Command-Z undid/redid formatting, and pasted list text continued on Return. CUA text selection did not reliably place a caret within the rendered Markdown, so that navigation step is not treated as an editor validation. The original workspace was restored without editing its documents.

## Quote and block styling

Added quote rules with normal body ink, larger paragraph spacing, compact blank lines, and tighter lists with muted markers. All 24 tests passed and the app bundle built successfully. Live inspection found concealed quote delimiters pulling the rule into the preceding line; anchored drawing to visible text and rebuilt. Final live check confirmed rule alignment and compact muted numbered lists without editing the user document.

## Unified page scrolling

Moved the inline header into the editor scroll surface and added a compact native toolbar title when it scrolls away. All 24 tests and the app build pass. Live checks confirmed scrolling down hides the header and reveals the toolbar title, scrolling to the top removes it, and restarting restores the saved scroll fraction (0.90438) and collapsed title. Header controls remain exposed in the accessibility tree. No document text was edited.

## Continuous editor pinch

Implemented continuous progress on the existing mounted editor surface, with a 3% dead zone, quadratic resistance, and an 18% outward release threshold. Reversal and cancellation settle back into writing; window deactivation also cancels. Reduce Motion skips scaling. Native event capture remains active until the gesture ends even after the page moves away from the pointer.

All 27 Swift tests pass with native pasteboard access, including three new resistance/reversal/threshold checks. The local app builds and passes code-signature verification. Live checks in `build/ContinuousPinchVerification` confirmed Command-0 opens the board, Escape restores editor focus, typing resumes at the cursor, branching retains text, and opening the original sheet restores its editor. No original workspace documents were edited.

Physical pinch delivery, cancellation, and Reduce Motion gesture behavior have not been verified end to end: the available native UI tool cannot generate magnification gestures. CAN-07 tracks that explicit verification gap. The curve tests do not substitute for a trackpad test.

## Zoom feel and pointer targeting

CAN-08 replaces the quadratic response with cubic ease-out, retains the dead zone/release safeguard, and rounds the moving page to match the board cards. Fixed the reported wrong-page zoom: the gesture previously opened `selectedID`, which could still identify the active draft. It now captures the page under the native pointer at gesture start and anchors zoom to that point; empty space selects no destination.

All 31 Swift tests and the app build/signature checks pass. Added checks for deceleration, other-page/empty-space/overlap targeting, anchor stability at zoom limits, and corner continuity. Inspected rounded cards and editor focus after a keyboard round trip in `build/ContinuousPinchVerification`; restored the original workspace without editing its documents. Physical pinch delivery and feel still require CAN-07 verification.

## Sidebar Command-Delete

Added an explicit native sidebar keyboard responder; Command-Delete invokes existing Trash handling only when that responder has focus. Plain Delete, extra modifiers, and repeated key events do not trash another file. Draft loading no longer steals focus after a sidebar click.

All 32 tests pass, including a native-window focus regression that verifies the shortcut works for the sidebar but not when an NSTextView owns focus. App build and signature verification pass. In `build/SidebarDeleteVerification`, clicked `Trash me` and used Command-Delete: the file left the sidebar through native Trash. Clicked the editor for `Keep me` and used the same shortcut: text was deleted while the file remained; Undo restored the text. Command-Delete in search cleared the query without trashing the file. Restored the original workspace and collapsed search. Only the disposable `Trash me.md` fixture was removed, recoverably through macOS Trash.

## Public release 0.1.2

Published on the owner's explicit request from commit `32574fd4ee953e5d108e9731b88c5a1e91bfa1a8`. CI run 34782878344 passed. Release run 34783029618 passed tests, universal build, packaging, archive/feed signing and verification, and publication. GitHub confirms `v0.1.2` is public and stable, with Matilde.dmg, appcast.xml, and SHA256SUMS uploaded. The unauthenticated stable DMG URL returns HTTP 200 and the latest feed advertises 0.1.2 with a 5,044,535-byte archive. No new install/relaunch test was performed for this version. Distribution remains ad-hoc signed and not Apple-notarized; physical trackpad checks remain CAN-07.

## Dotted canvas

Made the existing faint grid visible to match the supplied reference: 20-point spacing, 1.6-point dots, and 25% ink opacity. App build and signature verification pass. Inspected the pattern behind sheets and after scroll panning in `build/ContinuousPinchVerification`; restored the original workspace without changing writing. No additional tests were added or rerun for this visual-constant change.

## Canvas previews without goals

Removed the goal and flag from the shared canvas page preview; the editor and saved goal remain unchanged. App build and signature verification pass. In `build/ContinuousPinchVerification`, entered a disposable goal, confirmed it was absent from the board preview, and returned to the editor to confirm it remained saved and editable. Restored the original workspace without editing its writing. No unit tests were rerun for this presentation-only removal.

## Time-limited document zoom-out

The distance-only cubic curve could advance almost the entire flight in one native event; it did not limit speed in time. Added a cancellable interactive tracking task with a 1.8/sec progress cap, 160 ms smoothing, and a delayed-frame clamp. Outward settle duration now scales with remaining distance to bound cubic ease-out speed at 2/sec; opening retains its existing duration and Reduce Motion skips movement.

All 35 Swift tests pass, including large-input/delayed-frame limits, target convergence/deceleration, reversal/no overshoot, and release speed bounds. App build/signature checks pass. Relaunched normally, inspected the settled canvas after the toolbar transition, and returned with Escape to the focused editor without editing any writing. Native pinch delivery, cancellation, and subjective trackpad feel remain unverified (CAN-07); automated curve tests are not a substitute for that check.

### Faster tuning after owner feedback

The owner reported the first pass felt excessively slow. Reduced smoothing from 160 to 60 ms, raised tracking speed from 1.8 to 5 progress units/sec, and shortened release from 340–1500 to 180–420 ms. Regression tests now require over 98% target convergence within 400 ms and a maximum 420 ms release, alongside existing jump protection and reversal checks. All 35 tests and app build/signature checks pass. Relaunched and checked canvas/editor navigation without changing writing. Actual pinch feel still needs owner verification.

## Top-anchored wrapping header

The hosting view's unconstrained fitting measurement underestimated wrapped title height. Constrained the SwiftUI header to the editor width before measuring its vertical fitting size, retaining the header at y=0 and updating the body's inset with its full height. Added a native layout regression for short-to-long-to-short title changes and matching body displacement. All 36 tests and app build/signature checks pass. Live screenshots of the owner's existing one-line and two-line examples confirm identical draft-control/title top positions, with the goal and body moving down for the extra line. No writing was edited; restored the original draft selection.

## Quiet spelling

Disabled continuous spell checking in the writing editor; grammar checking was already disabled. Native manual spelling behavior is unchanged. All 36 tests and app build/signature checks pass. Relaunched and confirmed no red underline on the existing non-word. Right-click still exposes spelling guesses (No Guesses Found for that non-word), Ignore/Learn Spelling, and Check Document Now. No text was changed.

## Markdown divider

A standalone `---` (allowing surrounding whitespace) now draws a 1-point muted rule across the text column. Dashes remain in source with transparent glyphs and ordinary caret metrics; inline dashes and fenced code stay literal. All 38 tests and app build/signature checks pass. Added checks for Unicode/lossless styling, removing a dash restoring normal text, code protection, Return without list continuation, and undo with a native undo manager. Relaunched and visually inspected the divider the owner had already entered; no writing was edited. The prepared fixture under ignored `build/DividerVerification` was not needed for the live inspection.

### Divider focus follow-up

Hide the insertion caret on divider paragraphs and use a subtle accented rule for focus. Clicking selects the whole marker; Backspace with a collapsed caret anywhere on that paragraph removes the whole divider, and Return on a selected divider moves below it instead of replacing it. All 39 tests and app build/signature checks pass. Live click selected the entire existing marker without a caret through the rule; no writing was edited. Keyboard deletion/Return were verified with synthetic native text views, not the owner's documents.

### Directional navigation and full-line selection

Up/Left now skip divider paragraphs backward; Down/Right skip forward, including adjacent dividers. Single clicks move to the next paragraph; at a document boundary the divider is selected without inserting new content. Selected dividers get a full-width soft accent background instead of the native tiny hidden-dash selection rectangle. All 40 tests and app build/signature checks pass. Live inspection confirmed the full-width highlight, then clicked the divider and pressed Up: the caret landed on the blank paragraph above it rather than within the line. No writing was changed.

## Welcome document, images, and links — 2026-09-14

Implemented onboarding first: an editable welcome document with a sample goal, concise feature introduction, and a prompt to branch. It seeds once in an empty workspace. Existing writing and edited welcome documents are preserved; Help reopens the known document or creates a uniquely named replacement on explicit request. Tests cover seeding, no automatic recreation after Trash, recovery, and name collisions.

Images paste as PNG assets in a hidden `.assets` folder beside the draft, referenced by ordinary relative Markdown. Assets are retained through undo and Trash for branch/snapshot safety. Standalone image paragraphs render within the column (maximum display height 500 points); code stays literal. External URLs are not fetched. Bare URLs auto-link; pasting a URL over selected text creates a link; Command-K adds/edits a link with URL validation and escaped labels.

All 45 Swift tests and app build/signature checks pass. Media tests cover PNG import, invalid input, relative branch references, traversal rejection, lossless rendering attributes, code exclusions, URL paste, and escaped link labels. The first native clipboard check caught disabled Paste validation for image-only data in a plain NSTextView; fixed native command validation and repeated the check successfully.

In `build/OnboardingMediaVerification`, inspected the seeded page/goal, reopened it from Help without duplication, viewed images with text below, pasted an actual image copied from Preview, used Undo/Redo, branched and reopened the image-containing draft. Also pasted a URL over selected text and changed its destination with Command-K. Restored `/Users/ftsolov/Documents/Matilde` and its original selection without editing original writing. Finder file paste/drop, image-heavy performance, and external asset replacement are not yet verified end-to-end (EDIT-12). No release or version bump.

## Public release 0.1.3 — 2026-09-14

Published on the owner's explicit request from `76a8de3`. CI 34786021150 passed tests, app build, and packaging. Release run 34786127598 passed tests, universal build, packaging, archive/feed signing and verification, and publication. GitHub confirms v0.1.3 is public and stable with all three assets uploaded. The stable feed advertises 0.1.3 and the public DMG is available at 5,127,477 bytes. A fresh updater install/relaunch was not performed for this release. Distribution remains ad-hoc signed, not Apple-notarized. GitHub emitted a non-fatal Node 20 action-runtime deprecation warning; the run completed successfully.

## Settings foundation — 2026-09-14

Implemented the native Settings scene with Writing, Canvas, and Connections tabs. Writing size/line spacing and spelling use application preferences; canvas dots can be toggled. Text styling changes preserve source. Langdock keys use a separate generic-password Keychain service (`app.matilde.credentials`, account `langdock`), never the Sparkle signing-key service. The UI queries only presence, accepts masked replacement input, clears it after saving/closing, and confirms removal. No network request or AI integration is present.

All 48 tests, build, and code-signature checks pass locally. Added presentation-only styling tests, blank-key rejection, and an opt-in native Keychain lifecycle test. The latter saved/replaced/read/removed only a unique dummy test item and passed locally; it is skipped in normal CI without `MATILDE_TEST_KEYCHAIN=1`. No real API key was read or modified. Live UI verification and normal relaunch could not proceed because computer use reported the Mac is locked; UI-05 remains In progress for the remaining visual, focus, live-control, and persistence checks. No release/version bump.

After the owner unlocked the Mac, quit normally and relaunched the built app. Command-comma opened Settings; the Writing pane rendered at the default 19-point size/7-point spacing with spelling off. Connections exposed a masked secure field, Not configured status, and disabled Save for empty input. A control-test action was rejected because the owner changed the app; stopped modifying controls and left Connections open. No API key was entered or read. Live preference changes, Canvas controls, and persistence across restart still need checking.

## Public release 0.1.4 — 2026-09-14


Published on the owner's explicit request from `9464112`. CI 34786903569 passed tests, app build, and packaging. Release run 34787070147 passed tests, universal build, packaging, archive/feed signing and verification, and publication. GitHub confirms v0.1.4 is public and stable with all three assets uploaded. The stable feed advertises 0.1.4; the public DMG returns HTTP 200 at 5,212,431 bytes. A fresh updater install/relaunch was not performed for this release. Settings live-control/persistence checks remain open as documented above. Distribution remains ad-hoc signed, not Apple-notarized. The non-fatal Node 20 action-runtime deprecation warning remains.

## Document timestamps — 2026-09-14


Added relative edited dates to compact sidebar rows, document header, and canvas footer, refreshing every minute. Hover/accessibility exposes exact creation and edit dates. A separate `draft_dates` table preserves imported filesystem creation dates across atomic saves and tracks goal/title edits; filesystem modification dates expose external edits. Navigation, unchanged saves, and branching unchanged source text do not reset its age. Existing files cannot recover creation history already lost before import.

50 Swift tests ran with one opt-in Keychain test skipped and no failures. Timestamp tests cover relative labels, future-date clamping, imported dates, unchanged saves, navigation, branching, edits, rename, goal changes, reopening, and external modification. App build/signature checks pass. Quit normally and relaunched the built app; visually confirmed timestamps in sidebar, document header, and canvas without editing owner writing. No release or version bump.

## Two-line sidebar — 2026-09-14


Expanded document rows from 30 points to approximately 53 points. Titles occupy their own line; relative timestamps and optional main-document goals share a muted second line. Branches retain indentation and omit goals, including when search promotes a branch into the top row. Blank goals add no placeholder or separator. Existing selection, context menus, and keyboard handlers are unchanged. Build/signature checks pass; quit normally, relaunched, and visually checked populated/empty main rows and branches without changing writing. Unit tests were not rerun for this layout-only change. No release/version bump.

Follow-up: removed document and branch icons, increased sidebar timestamps from 10 to 12 points, and grouped each family's branches under one continuous 1-point muted vertical guide. The guide is decorative and does not intercept clicks or accessibility. Build/signature checks pass; restarted normally and visually verified guides under two parents, standalone items without guides, and larger timestamps. No writing edited; unit tests not rerun for this presentation-only refinement.


## 2026-09-14 — Stash first implementation

54 Swift tests, with one opt-in Keychain skip and no failures; production bundle/signature verification passed. New storage/model tests cover shared family ownership, retained orphans, unchanged draft dates, Unicode, position persistence, conflicts, symlinks, and failed saves. Live disposable-workspace checks covered the welcome exercise, typing/list continuation, Unicode paste, undo/redo, close/focus return, branch sharing, canvas scroll/close, rapid toggles, and quit/relaunch. Original workspace restored. See [stash implementation notes](stash.md) and STASH-02 for remaining acceptance checks; no release.


## 2026-09-14 — Stash spacing refinement

Removed the ownership subtitle and set stash text/placeholder to the header’s 16-point inset, eliminating native extra line-fragment padding in this panel. Production build and signature checks passed. Restarted normally and visually confirmed the title and existing stash text align, with no subtitle; no writing was edited.


## 2026-09-14 — Stash corner placement

Moved the stash panel and tucked entry point to the bottom-right of the writing area, mirroring the lip shape and outer inset. Updated future welcome-document copy without rewriting existing documents. Production build/signature checks passed; normal restart and live visual inspection confirmed the open panel at the bottom-right. No writing was edited.


## 2026-09-14 — Stash edge and spring refinement

Stash is 360 points tall (previously 300), meets the bottom window edge, and rounds only its upper corners. Open/close uses a spring with 0.24-second response and 0.78 damping; hover uses 0.20/0.80. Reduce Motion retains immediate transitions. Production build/signature checks passed. Normal restart, screenshot inspection, and quick close/reopen confirmed bottom-flush layout, increased height, and reliable focus. Subjective spring feel remains for owner review; no writing was edited.


## 2026-09-14 — Version 0.1.6 release preparation

Owner explicitly requested committing, pushing, and a new version. Local default set to 0.1.6 with stash release notes. Existing STASH-02 verification gaps remain tracked; release automation will rerun tests, build universal binaries, and verify signed artifacts before publication.


## 2026-09-14 — Stash pull-tab refinement

Replaced the tucked document-icon button with a 76-point-wide Stash pull tab, small grip, symmetric 4-point upper corners and square lower corners. Extra right inset keeps the tab clear of native window-corner clipping. Spring response increased from 0.24 to 0.32 seconds with 0.82 damping, and hover from 0.20 to 0.26 seconds with 0.84 damping. Production build/signature and diff whitespace checks passed. Live inspection/restart was blocked by the locked Mac; no UI verification is claimed.


## 2026-09-14 — Roomier lines and list alignment

55 Swift tests ran, one opt-in Keychain skip, no failures; production build/signature and whitespace checks passed. A native glyph-layout regression verifies first-word/continuation alignment for bullets, numbered lists, and both checklist states at 17, 19, and 24 points, along with preference preservation and unchanged Markdown. Restarted normally and visually inspected existing writing without editing it: roomier lists in both editors, aligned wraps, and the wider 420-point stash. Existing custom line-spacing preferences are preserved; default is now 9 points.


## 2026-09-14 — Adaptive stash height

56 Swift tests ran with one opt-in Keychain skip and no failures; production app/signature checks passed. Native measurement test covers short content, long wrapping content, narrower container reflow, available-window clamping, and clearing content back to minimum height. Live restart/inspection was deferred when computer use detected owner activity and fresh state showed ongoing stash writing; no text was edited by the agent. Updated build is ready for the next normal restart.


## 2026-09-14 — Sidebar newest first

Sidebar-only grouping sorts document families by their latest member edit and branches newest-first beneath a stable representative. Folder order remains unchanged. Regression tests cover recent branch activity, parent preservation, standalone ordering, filtered/orphan groups and deterministic ties. 58 Swift tests ran with one opt-in skip and no failures; build/signature checks passed. Restarted normally and confirmed Plugins changelog first, Matilde product inspiration second, then older families. No writing was edited.


## 2026-09-14 — Compact family sidebar

59 Swift tests ran, one opt-in Keychain skip, no failures; production build/signature and whitespace checks passed. New persistence regression covers remembering a branch independently of another family, reopening the workspace, missing remembered drafts, and selecting the original again. Restarted normally and inspected one row per family, alternate counts, matching goal/timestamp typography and right alignment. Owner text was not edited. Per-family persistence is regression-tested; no manual draft-switch exercise was performed on owner writing.


## 2026-09-14 — Sidebar fallback and count spacing

Empty/whitespace-only sidebar goals display “No goal set”. Branch icon/count use an explicit 3-point gap. Production build/signature checks passed; normal restart and screenshot inspection confirmed both changes without editing writing.


## 2026-09-14 — Header navigation and divider entry

Removed the editor-header timestamp. Title and goal now share a focus scope: unmodified Down/Return/Tab advance, Up from goal returns to title; modified keys retain native behavior. Completing a standalone divider by typing the third hyphen (or inserting three hyphens) inserts the following newline in the same native edit, leaving an empty caret below. Inline dashes and fenced code stay literal. 60 Swift tests ran with one opt-in skip and no failures, including Unicode divider completion/caret, undo, and code exclusion. Production build/signature checks passed. Live restart was deferred when computer use reported owner interaction; keyboard UI verification remains EDIT-14.


## 2026-09-14 — Dark mode and sidebar Settings

61 Swift tests ran with one opt-in Keychain skip and no failures; production build/signature checks passed. New palette test resolves light/dark colors and verifies body-text contrast above 7:1. Live verification opened Settings via the sidebar gear, selected General → Dark, inspected native writing/code text, sidebar, stash and canvas previews, then quit/relaunched to verify persistence. Left Dark selected. No writing was edited. System-following uses native appearance inheritance; automatic OS switching and branch-curl appearance remain unverified live.


## 2026-09-14 — Neutral dark palette

Reduced dark-mode saturation across paper, sidebar, canvas, underside, ink and accents. Light palette unchanged. Palette/contrast test and production build/signature checks passed. Normal restart and live visual inspection confirmed neutral charcoal surfaces and less yellow text; no writing edited.


### 2026-09-14 — Caret and inline-code alignment

- Caret drawing now uses the current glyph baseline and font cap height/descender instead of the full native insertion rectangle. Empty trailing paragraphs retain native geometry.
- Inline code uses a custom layout-manager background fitted to each wrapped run, avoiding highlights that extend through paragraph spacing. Its monospaced font scales with writing size and aligns by x-height.
- Added regression coverage for wrapped inline code, Unicode source preservation, three font sizes, and two line-spacing values. `swift test --disable-sandbox`: 62 tests, one existing skip, no failures. App assembly and signature verification passed.
- Relaunched normally and inspected the existing document without changing its text: dark-mode inline-code highlight is compact and the caret sits beside the letters. Light-mode visual inspection was not repeated for this change.


### 2026-09-14 — Copy current draft

Added Copy Markdown to the document actions menu. It writes the live model body to the native clipboard as a string, preserving Markdown and including edits before autosave. Title, goal, and stash are excluded. Build/signature checks passed; restarted normally and confirmed the enabled menu entry. Cross-app paste was not exercised, and owner writing was not modified.


### 2026-09-14 — Remove canvas appearance option

Removed the dotted-canvas toggle, Canvas Settings tab, and stored-preference dependency. Board dots now always render. App build/signature and diff checks passed; after a normal restart, Settings exposes only General, Writing, and Connections. No release triggered.


### 2026-09-14 — Header arrow-key routing correction

The previous modifier check rejected arrow events carrying non-user modifier flags. It now checks only Shift/Control/Option/Command. Goal-to-body focus runs on the next main-queue turn so SwiftUI can resign its field first. Normal restart and live focus-only checks confirmed title Down → goal, goal Up → title, and goal Down → writing editor without changing document text. Build/signature and 62 Swift tests passed (one existing skip). Enter/Tab and divider live acceptance remain recorded under EDIT-14.


### 2026-09-14 — Checkbox creation

Added Writing → Checkbox (Shift-Command-L) routed to the focused native editor, including stash. It converts the current paragraph or bullet to a task and toggles an existing task. Typing a space after a standalone `[ ]`, `[x]`, or `[X]` creates the Markdown task prefix; fences remain literal. Checkbox clicks inside code blocks are now ignored.

64 Swift tests passed with one existing skip, covering Unicode, conversion, toggle, undo/redo, continuation, empty-list exit, and code protection. Final app build/signature passed. In ignored build/checkbox-workspace, verified rendered checked/unchecked boxes, mouse toggle, shorthand typing, Return continuation, and the stash keyboard shortcut. Restored the original workspace and active document without editing owner writing.


### 2026-09-14 — Filled rounded checkbox styling

Checkboxes now draw rounded filled shapes over the existing marker geometry. Unchecked boxes use a soft ink tint; checked boxes use solid ink with a contrasting rounded checkmark. Underlying Markdown, layout widths, and click handling are unchanged. Build/signature and diff checks passed. Inspected both states in the disposable checkbox workspace in light mode, then restored the original workspace. Dark-mode appearance was not separately inspected.


### 2026-09-14 — Slash insertion menu

Added a nonactivating native child panel with no animation. Slash commands open at a word boundary outside code, filter by title/aliases, support Up/Down and Enter or click, and dismiss on whitespace, Escape, or focus loss. Enter replaces only the slash query with a Markdown template and selects its editable placeholder. Block templates separate themselves from surrounding inline text. Catalog includes six heading levels, bullet/numbered lists, checkboxes, quotes, dividers, fenced/inline code, bold/italic, links, and local-image Markdown references. Image entries select a path placeholder rather than opening a file picker.

66 Swift tests passed with one existing skip, covering query boundaries, URL/code exclusions, Unicode ranges, matching, replacement/selection, divider caret, and undo. Build/signature passed. Isolated live checks verified the unfiltered popup colors and top position, /check replacement, space dismissal preserving literal text, and /h3 insertion in stash. Original workspace restored; no owner writing edited. Screen-reader navigation and very narrow-window behavior remain unverified.


### 2026-09-14 — Slash menu visual refinement

Added SF Symbols in a fixed 18-point column, a 10-point icon-to-label gap, 12-point row content insets, 34-point row height, and 6-point outer padding. Menu width is 248 points, with 12-point outer corners and 8-point selection corners. Scrollbars overlay and hide when idle. Existing filtering and insertion behavior is preserved.

Both existing slash regression tests passed. Production app build/signature passed after rerunning outside the sandbox for macOS icon generation. Live inspection was blocked by automatic approval review because launching the app might expose the owner's private workspace; no workspace or writing was modified. Visual acceptance remains pending under EDIT-19.


### 2026-09-14 — Slash menu visual acceptance

After explicit owner approval, inspected the updated app using `build/slash-style-workspace`. Light-mode menu icons, label alignment, row padding, rounded selection, keyboard scrolling to Numbered list, filtered `/check` insertion with selected Task placeholder, and `/link` popup placement in the stash passed. Escape dismissed the stash popup. Restored the original workspace and active document without editing owner writing. Dark-mode visual inspection and screen-reader navigation were not repeated. EDIT-19 is complete.


### 2026-09-14 — Quieter grouped slash menu

Matched the revised reference with muted Format/Lists/Insert/Style labels, explicit H1–H6 marks, larger 14-point item labels, and lighter icons/selection. Reduced outer corners to 8 points and selection corners to 6, with a 0.5-point low-opacity border. Replaced the native panel shadow with a controlled 8%-opacity, 5-point-radius layer shadow. Group labels are excluded from keyboard selection.

Two slash regression tests and production build/signature passed. Inspected the running light-mode menu in the disposable slash-style workspace, including labels, border, corners, and heading marks. Six Down presses crossed the Format/Lists boundary and Return inserted the expected bullet template with Item selected. Original workspace and active document restored without editing owner writing. Dark-mode and screen-reader checks were not repeated.


### 2026-09-14 — Initial manual Langdock integration

Implemented model discovery/settings, a native completion client, manual review with optional accepted rewrites, per-draft SQLite history and conservative stale/cancellation handling. Requests use JSON mode plus local validation, not strict JSON Schema enforcement.

76 Swift tests passed (one existing skip); app build and code-signature verification passed. Synthetic transport and review tests cover request shape, redacted auth errors, malformed/truncated responses, UTF-16 anchors, ambiguity/overlap, history, switching/edit cancellation, acceptance and undo. In `build/langdock-workspace`, a saved synthetic comment selected its exact source; acceptance changed only that passage and Command-Z restored it. Settings Connections layout inspected. Original workspace and active document restored without editing owner writing.

No saved API key was configured, so live Langdock authentication/model discovery/completions and quality, cost and latency remain unverified. No personal writing was sent during verification.


### 2026-09-14 — Resizable writing-review panel

Increased default width from 280 to 380 points, added native edge dragging bounded to 320–560 points, persisted width and double-click reset. Solid cards now have borders and a small shadow; quoted passages have an accent rule and divider, and replacements have a labeled inset background. App build/signature passed after rerunning outside the sandbox for iconutil. Inspected existing saved comments without editing writing or requesting another review; drag resizing and double-click reset passed live. Dark-mode appearance, VoiceOver resizing and width restoration across relaunch were not verified in this pass.


### 2026-09-14 — Floating passage review cards

Replaced the review sidebar background/divider and resize handle with a transparent margin containing cards positioned from actual TextKit line coordinates. Compact cards expand to content-sized feedback with bounded internal scrolling; neighboring cards stack below them. Selection applies a temporary source highlight without modifying Markdown. Smaller windows use comment buttons with popovers. Saved runs remain available through Review history.

Seven review regression tests and the production app/signature build passed. In the running app, existing saved comments aligned with their passages, expansion pushed the next card down, and the linked passage remained highlighted. No writing was edited or sent. The displayed document fit within its viewport, so sustained scroll tracking on a long document remains unverified, as do narrow-window popovers, dark appearance and VoiceOver.


### 2026-09-14 — Review overlay beside the text

Removed WritingReviewPane from the root HStack and placed it over the writing surface below StashPocket. Horizontal positioning now comes from the actual native editor text edge plus 16 points; card width uses the available margin, falling back to compact popovers when needed. Opening reviews no longer reserves a column or changes writing layout.

Production build/signature and diff checks passed. Restarted normally and inspected existing saved reviews: cards sit directly beside the text; opening the stash visibly covers the cards. Closed stash afterward. No writing was edited or transmitted. Narrow-window and dark-mode checks were not repeated.


### 2026-09-14 — 0.1.8 release preparation

Review quotes, explanations, rewrite text and controls now use the standard system UI body font instead of smaller caption/callout styles. Restarted and inspected the saved floating cards in light mode. Full Swift suite: 76 tests, one opt-in skip, no failures. Both Python release tests and local app/signature build passed. Version set to 0.1.8 for the owner-requested release, including manual Langdock reviews, slash insertion and checkbox refinements.


### 2026-09-14 — Review blockquote styling

Unified compact and expanded source quotes with a shared view using the editor’s muted two-point rule at 55% opacity and 24-point indent. Standard system UI font size remains unchanged. App build/signature and live light-mode compact-card inspection passed after normal restart. Existing writing and review content were not changed.


### 2026-09-14 — Apple silicon distribution only

Build script now always compiles arm64 and removes the Intel compile/lipo merge branch. CI and DMG packaging require exactly arm64 for the Matilde executable; release feed verification requires `sparkle:hardwareRequirements` = `arm64`. Release workflow and download documentation reflect Apple silicon only. macOS 14 minimum retained because no current compatibility code can be removed by raising it. Sparkle vendor framework/helper slices remain unchanged.

ARM-only app build and deep signature verification, DMG packaging, generated arm64 appcast requirement and feed/archive Ed25519 verification passed locally. Two Python release tests, shell syntax checks and git diff check passed. Used only ignored local 0.1.8 artifacts for this verification; published 0.1.8 assets were not changed, no version bumped and no release dispatched. Real Intel updater presentation remains untested; hardware filtering relies on the installed Sparkle 2.9.6 support.


### 2026-09-14 — 0.1.9 release preparation

Reduced review quote indentation from 24 to 10 points in the shared compact/expanded quote view. Includes the Apple-silicon-only distribution changes and arm64 feed requirement. Full Swift suite passed: 76 tests, one skip, no failures; both Python release tests and ARM app/signature build passed. Final visual inspection could not run because the Mac was locked. Version set to 0.1.9 at the owner’s explicit release request.


### 2026-09-14 — Editable side-by-side drafts

Added DraftComparison session and native HSplitView, entry points in the document menu, draft tray, sidebar and canvas, and a second-draft selector/close control. Both bodies are editable with separate buffers, positions, autosave and undo managers. Comparison writes refresh draft identity after renames, preserve dirty text on external conflicts and flush on close, switch and app termination.

80 Swift tests passed (one opt-in skip), including independent buffers/positions, conflict recovery, debounce after rename and isolated native undo; app build/signature passed. Live checks in ignored `build/comparison-ui` covered edits on both sides, Command-S to separate files, right-side undo preserving the left edit, divider dragging and saving pending edits on close. Initial live check exposed a shared window undo manager; fixed with per-editor managers and repeated successfully. Original workspace and Untitled document restored without editing owner writing. Separate-window support, comparison restoration across launch and synchronized scrolling are outside this increment.


### 2026-09-14 — 0.1.10 release preparation

Owner requested committing, pushing and releasing the editable comparison feature. Set version 0.1.10 and added release notes. Re-ran the full Swift suite (80 tests, one opt-in skip, no failures), both Python release tests and ARM app/signature build successfully. Live comparison checks are recorded above.


### 2026-09-14 — Permanent Pen assist header

Renamed the review header Pen assist and made it visible for every active draft, removing the open/closed flag, icon menu and close button. Review/Cancel is a plain same-line action; history lives in the text title menu. Compact layouts keep a visible text title and put review in its menu. Floating cards and stash layering remain intact; no automatic API request is made.

Seven review tests and the ARM app/signature build passed. Restarted and verified the permanent title and aligned Review action in the running light-mode app without editing writing or sending a request. Compact/dark presentation was not repeated.


### 2026-09-14 — 0.1.11 release preparation

Final header name is Writing assist, including accessibility/help text and current product documentation. Normal restart confirmed the new name. Owner requested publication: version set to 0.1.11 with release notes covering the always-visible header and aligned Review action. Full Swift suite passed (80 tests, one opt-in skip), both Python release tests and ARM app/signature build passed.

## Writing assist follow-up and comparison persistence — 2026-09-14

- 86 Swift tests passed, one existing opt-in test skipped; app build and signature verification passed.
- Added regression coverage for Unicode anchors moving around edits, only-overlap invalidation, old review decoding, persisted reply/rewrite data, stale reply cancellation, automatic review debounce/pause/switch cancellation and Unicode line differences.
- Disposable `build/assist-ui` fixture: thirty sections, two editable drafts, two nearby review cards. Verified line highlights on both sides, compact scrollable reply popovers, expanded cards without overlap and comments leaving view when scrolling.
- Sent a synthetic question through the configured Langdock connection. Received and persisted a reply plus optional rewrite; draft remained unchanged. Thread restored after normal quit/relaunch.
- Native split initially failed to save because macOS includes its divider decoration in subviews. Corrected discovery to use arrangedSubviews. Verified saved 57% restoration, then dragged to 51.888% and relaunched at the same 769.5-point position.
- Original workspace and original active draft restored without editing owner writing. No version bump or release.
- Dark-mode comment contrast and extended-use automatic review quality/cost remain explicit roadmap verification follow-ups; timer behavior is covered with deterministic tests.

## Selection threads and optimistic replies — 2026-09-14

- 87 Swift tests passed with one existing skip; app build/signature and diff whitespace checks passed.
- Added exact repeated-phrase/Unicode selection coverage and assertions for immediate pending publication, cancellation retaining the question, retry without duplicates and successful sent/assistant state. Updated cancellation regression to expect the preserved failed message.
- In disposable `build/selection-ui`, mouse-selected a sentence and clicked Ask Writing assist. The anchored composer opened with keyboard focus. A live Langdock request returned an optional rewrite without editing the draft, and its thread survived relaunch.
- Fixed a shortcut conflict discovered during verification: Shift-Command-L remains Checkbox; Shift-Command-A is Ask about Selection. Verified the final shortcut focuses a composer on another selected passage, and the native context-menu action is enabled.
- Loading/cancellation/retry transitions are covered by deterministic model tests; the live request completed before the automation snapshot, so its transient Thinking indicator was not separately captured.
- Restored the owner's current workspace and active “EU Flip Linkedin post — No image” draft. No owner writing was edited. No release/version change.

### Selection action placement correction

Moved Ask Writing assist from a text-view subview to a nonactivating child panel above the first selected line, eight points away. An opaque native-drawn paper surface prevents underlying text showing through; scrolling, resizing, selection changes and focus loss dismiss it. App/signature build passed. Verified above-selection placement and click-to-focused-thread with a multiline selection in `build/selection-ui`; original workspace and active draft restored. No writing or release changes.

### Conversation layout — 2026-09-15

User messages now use a muted accent surface and label; assistant messages use a neutral surface. Expanded conversation transcripts scroll independently above a fixed composer/actions footer. Removed Collapse; an event boundary collapses on outside clicks, Escape, keyboard focus leaving via Tab, or window blur. Build/signature passed. With a disposable eight-message thread, visually verified role distinction, unchanged composer position after scrolling, retained focus on composer clicks, and collapse when clicking the document. Original workspace/draft restored. No live requests or owner-text edits were needed for this layout check.

### Conversation focus refinement — 2026-09-15

Removed Dismiss from conversation controls; blur preserves the thread as a shortened card. Added a 280ms spring for expand/collapse and changing transcript height, disabled under Reduce Motion; previews have scoped native pointing-hand cursor regions and a hover tint, while selected cards have an accent border/shadow. Input focus is requested after mounting on every open, including reopening existing threads. App/signature build and diff check passed. Disposable-thread UI checks verified first-open and reopen autofocus, focused border, absent Dismiss/Collapse controls, and outside-click shortening without removal. Original workspace/draft restored. Animation timing and native pointer appearance were not captured frame-by-frame by the UI automation.

### Keychain prompt reduction — 2026-09-15

API requests previously performed a Keychain data read every time. Added a locked, process-only shared cache, populated only on successful reads/saves and invalidated by save/remove. Background automatic reviews now use cached credentials exclusively, so cannot initiate a Keychain password prompt. They wait for the first manual request or key save in each app session. 89 Swift tests passed, one opt-in Keychain test skipped. New synthetic tests verify reuse, identity isolation, replacement/removal and uncached authorization errors. Real secrets and Keychain access controls were not read or altered for testing. App/signature build passed. First-access prompts across ad-hoc rebuilds remain possible; Apple TN3127 documents their version-specific designated requirements. Stable Developer ID signing remains the cross-build solution.


### 2026-09-15 — Plain chat messages and streamed replies
- Removed per-message background/padding; preserved role label colors, outer card and sticky composer.
- Added bounded SSE reply transport, transient incremental text, Thinking/Writing states and final validated JSON before persistence/rewrite availability.
- 93 Swift tests passed, one existing opt-in Keychain test skipped. Synthetic transport verifies incremental callbacks and stream/JSON request flags; parser tests cover split escapes/surrogates, refusal, truncation, malformed payloads and size limits.
- App build/signature passed. Restarted normally and inspected an existing conversation read-only: plain aligned messages and distinct labels are visible. No writing or credentials edited, and no live API request sent. Live provider streaming remains unverified.

### 2026-09-15 — Conversation corner seam
Removed nested transcript card decoration in expanded threads while preserving history cards. App/signature build passed; restarted normally and inspected an existing conversation read-only, including scrolling to its end. The transcript/composer boundary is straight and only the outer card rounds at the bottom. No writing changed or requests sent.

### 2026-09-15 — Inline thinking shimmer
Thinking appears in the pending assistant response, replaced by incremental answer text. The footer no longer includes a spinner/loading row; Cancel occupies Send’s position during the request. Added a masked 1.6-second linear highlight with static Reduce Motion fallback and scroll-to-pending-response. App/signature build passed. Inspected the actual SwiftUI shimmer component in a disposable native preview using synthetic labels; no writing or API access. Preview closed normally. Matilde quit normally, but relaunch verification was blocked by the Mac locking. Integrated request/Reduce Motion checks not performed.

### 0.1.12 release verification
Initial release CI exposed a fixed-delay retry test race on a slower runner. Replaced its 140ms sleep with an expectation observing request completion (bounded to five seconds), preserving all delivery/deduplication assertions.
A subsequent runner exposed the equivalent automatic-review sleep race; automatic review now signals its invocation and successful reply tests await the model’s idle state. Negative debounce/pause/cancel observations retain bounded waits.

### 2026-09-15 — Stronger thinking shimmer
Widened the sweep from 60% to 85% of text width and added a full-ink plateau across its center, preserving speed and Reduce Motion behavior. App/signature build passed; actual component inspected in a disposable native preview. Preview closed and Matilde restarted normally. No API requests sent.

### 2026-11-15 — Sidebar moves, folder new note, permanent search, hidden scrollbars (UI-13–UI-16)
Built in a Linux sandbox without Swift, so all checks ran on CI (macOS-15, PR #1). 99 Swift tests passed with one existing opt-in Keychain skip, including the six new `NoteMoveTests`. App bundle build and packaging checks passed. Not yet verified on a Mac: drag/drop delivery with the declared `app.matilde.local.note` type, drop highlight, hover `+` placement, search field layout, and scrolling with hidden scrollers (trackpad, wheel, Page Up/Down, arrow keys) in the sidebar, editor, comparison, stash, board, slash menu and Writing assist.

### 2026-11-15 — Ask Matilde rename, toolbar, shortcut and comment anchoring
- Renamed user-visible "Writing assist" to "Ask Matilde"; moved review, pause/resume and history into one toolbar control; ⇧⌘A works without a selection (current paragraph, or a review on an empty line).
- AI and private comments now share range tracking and disappear only on full passage deletion (undo restores) or explicit deletion; title/goal changes keep them.
- CI (macOS-15, run 43714079370): 113 Swift tests passed with one opt-in skip; app build, signature and packaging checks passed. No Mac UI session was available, so the toolbar look, menu shortcut display, error states and live edit/undo behaviour are unverified.

### 0.1.14 release preparation — 2026-11-15
Owner requested "merge all and do a new release". Squash-merged PR #1 (`6674de2`, sidebar moves, folder new note, permanent search, hidden scrollbars) and PR #2 (`71395d5`, Ask Matilde guidance/toolbar/shortcut, private comments, passage-following comments) after green CI; the merged PR #2 head passed CI with 119 Swift tests (one opt-in skip) plus build, signature and packaging checks. Version set to 0.1.14 with release notes covering both. Live Mac UI checks listed under UI-13–UI-16, EDIT-22, AI-12 and AI-13 remain open.

### 0.1.14 publication — 2026-11-15
Release workflow run 43715121106 (dispatched on `main` at `189b5e0`, version 0.1.14) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing and publication. GitHub Release `v0.1.14` is published as latest with `Matilde.dmg`, `appcast.xml` and `SHA256SUMS`. The latest feed reports version 0.1.14, `arm64` hardware requirements, the v0.1.14 DMG URL and an Ed25519 signature. Build remains ad-hoc signed and not Apple-notarized (DIST-02). An installed-app update from 0.1.13 was not exercised.


### 2026-11-15 — Node 24 GitHub Actions (DIST-05)
Release run 43715121106 and CI runs 43715288846/43714955252 carried the Node.js 20 deprecation annotation for `actions/checkout@11d5960…` and (Release only) `actions/upload-artifact@ea165f8…`; no other deprecation annotations were present. Updated to `actions/checkout` v7.0.1 (`3d3c42e5…`) and `actions/upload-artifact` v7.0.2 (`cf430e03…`), both `node24`, without input changes, and added `.github/dependabot.yml`. CI on PR #3 (run 43717276007, macOS-15) passed 119 Swift tests with one opt-in skip plus build, signature and packaging checks; its check-run annotations contain only GitHub's macOS arm64 queue-time notice. `actionlint` 1.7.12 passes both workflows. The Release workflow was not run (that would publish), so its new checkout and artifact upload are unverified until the next owner-requested release.

### 0.1.15 release preparation — 2026-11-15
Owner requested a new release after merging PR #4 (`be46e7c`, margin comments), PR #5 (`ad235ca`, spell-check crash fix and spelling markers) and PR #6 (`0e2c6f4`, centered layout, card cleanup, Stash in toolbar, branch naming). PR #5 and the merged PR #6 head passed CI (macOS-15) with build, signature and packaging checks; locally 122 Swift tests passed with one opt-in skip using a Swift 5.9 shim (3 pasteboard tests excluded by the sandbox). Version set to 0.1.15 with release notes. Live Mac UI checks for EDIT-22–EDIT-24 and UI-07 remain open.

### 0.1.15 publication — 2026-11-15
Release workflow run 43725499642 (dispatched on `main` at `20a6989`, version 0.1.15) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing and publication; this was also the first Release run with the Node 24 checkout/upload-artifact actions (DIST-05). GitHub Release `v0.1.15` is published as latest with `Matilde.dmg`, `appcast.xml` and `SHA256SUMS`; the latest feed reports version 0.1.15 with `arm64` hardware requirements. Build remains ad-hoc signed and not Apple-notarized (DIST-02). An installed-app update from 0.1.14 was not exercised.

### 2026-11-15 — Tabler interface icons (UI-17)
Replaced every SF Symbol outside native menus with Tabler Icons `v3.52.0` (MIT), outline style redrawn at a 1.5 stroke (Tabler default 2; `STROKE_WIDTH` in `scripts/tabler-icons.py`). Resources: unmodified SVGs in `assets/tabler-icons/{outline,filled}/` with Tabler's LICENSE; the script converts them with cairosvg to 24 × 24 pt single-page vector PDFs in `Sources/Matilde/Resources/Icons/` (with LICENSE and SOURCE.md), copied by SwiftPM into `Matilde_Matilde.bundle`, which `build-app.sh` already places in `Contents/Resources`. `MatildeResources.bundle` (shared with the fonts) finds it in both `swift test` and the app. PDFs are committed, so CI needs no new tool. `MatildeIcon.image(size:)` returns a fixed-size template `Image` (toolbars, menus and tab items ignore frames); `.image` is the resizable variant; `nsImage(size:)` sets `isTemplate`.

| Location | SF Symbol | Tabler icon (`MatildeIcon`) | Size (pt) |
| --- | --- | --- | --- |
| Toolbar: toggle sidebar | `sidebar.left` | `layout-sidebar` (`.sidebar`) | 20 |
| Toolbar: new document; sidebar Documents header | `square.and.pencil` | `edit` (`.newDocument`) | 20 / 18 |
| Toolbar: board ↔ draft | `square.grid.2x2` / `doc.text` | `layout-grid` / `file-text` | 20 |
| Toolbar: Ask Matilde control (idle / reviewing / error) | `text.bubble` / `stop.circle` / `exclamationmark.bubble` | `message` / `player-stop` / `message-exclamation` | 20 |
| Toolbar: Stash (closed / open) | `tray` / `tray.fill` | `inbox`, now a button-style toggle | 20 |
| Toolbar: document actions | `ellipsis.circle` | `dots-circle-horizontal` (`.more`) | 20 |
| Sidebar search field / clear | `magnifyingglass` / `xmark.circle.fill` | `search` / `circle-x` (`.clear`) | 14 / 15 |
| Sidebar new folder | `folder.badge.plus` | `folder-plus` | 18 |
| Folder row (collapsed / expanded) | `folder` / `folder.fill` | `folder` / `folder-open` | 18 |
| Folder row disclosure | `chevron.right` / `chevron.down` | `chevron-right` / `chevron-down` | 14 |
| Folder row hover new note | `plus` | `plus` | 18 |
| Sidebar Settings button; General tab | `gearshape` | `settings` | 18 / 24 |
| Sidebar row branch count | `arrow.triangle.branch` | `git-branch` (`.branch`) | 14 |
| Draft header: drafts disclosure / branch | `chevron.up`/`chevron.down` / `arrow.triangle.branch` | `chevron-up`/`chevron-down` / `git-branch` | 13 / 17 |
| Goal flag (editor header, comparison header) | `flag` | `flag` (`.goal`) | 17 / text size + 4 |
| Draft tray active draft | `checkmark` | `check` | 13 |
| Comparison picker / close; Stash close | `rectangle.split.2x1` / `xmark` | `layout-columns` / `x` (`.close`) | 16 / 16, 14 |
| Board zoom out / in / fit | `minus` / `plus` / `arrow.up.left.and.arrow.down.right` | `minus` / `plus` / `arrows-diagonal-2` | 15 |
| Board active sheet | `pencil.tip` | `pencil` (`.activeDraft`) | 14 |
| Narrow-window margin markers (review / private comment) | `text.bubble.fill` / `note.text` | `message` / `note` | 17 |
| Comment card and popover archive | `archivebox` | `archive` | 16 |
| Comment composer Done / Send / Stop | `checkmark.circle.fill` / `arrow.up.circle.fill` / `stop.circle.fill` | `circle-check-filled` / `circle-arrow-up-filled` / `player-stop-filled` | 20 |
| Rewrite Accept | `checkmark` | `check` | 14 |
| Settings tabs Writing / Ask Matilde / Connections | `textformat` / `text.bubble` / `key` | `typography` / `message` / `key` | 24 |
| Slash menu | `textformat.size`, `list.bullet`, `list.number`, `checkmark.square`, `text.quote`, `minus`, `curlybraces`, `bold`, `italic`, `chevron.left.forwardslash.chevron.right`, `link`, `photo` | `heading` (not drawn: rows show H1–H6), `list`, `list-numbers`, `checkbox`, `quote`, `minus`, `braces`, `bold`, `italic`, `code`, `link`, `photo` | 24 drawn into the existing 18-pt slot |

Kept on SF Symbols: `doc.on.doc` (Copy Markdown in the document menu) and `trash` (Move to Trash in sidebar, tray and board context menus). These are native NSMenu items where macOS draws its own menu imagery, so a custom glyph would look out of place beside system items. Window controls, menu checkmarks and the app icon are system-drawn and untouched. Filled variants are used only for the solid composer buttons, whose filled disc and dimming show enabled state; Tabler has no filled tray, so Stash shows its open state with the native toggle bezel instead.

Linux sandbox without Swift: `python3 -m unittest discover -s scripts/tests` passed (new `test_icons.py`: every enum case has an SVG and a one-page 24 × 24 vector PDF at the current stroke, no unused files, licenses present, `Package.swift` copies the folder, and only the two kept SF Symbols remain). CI on PR #9 (run 43726158152, macOS-15) passed 127 Swift tests with the one existing opt-in skip, including the new `MatildeIconTests` (every case loads from the bundle as a template vector image and renders; sized copies stay template), with no compiler warnings; the app build, signature and packaging checks passed, including the new step that found all 45 icon PDFs and the LICENSE inside the built `.app`. Not verified on a Mac: visual size/baseline match against the previous symbols, toolbar toggle bezel for Stash, Settings tab image rendering, light/dark tinting and VoiceOver labels.

### 0.1.16 release preparation — 2026-11-15
Owner requested "pls merge it and do a new release". Latest tag was `v0.1.15`, so this is 0.1.16. Squash-merged PR #9 (`bc4bc9d`, Tabler interface icons, UI-17) after its head `451b3f4`, already containing main, passed CI run 43726328125 (macOS-15: 127 Swift tests with one opt-in skip, build, signature and packaging checks including 45/45 bundled icons). The only other change since v0.1.15 is #8 (publication record, docs only). Version set to 0.1.16 with release notes. Live Mac UI checks for UI-17 remain open.

### 0.1.16 publication — 2026-11-15
Release workflow run 43728100211 (dispatched on `main` at `470e7fa`, version 0.1.16) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing, the Node 24 `upload-artifact` step (artifact `Matilde-0.1.16`, 5.5 MB) and publication; its only annotation is GitHub's macOS arm64 queue-time notice. GitHub Release `v0.1.16` is published as latest with `Matilde.dmg`, `appcast.xml` and `SHA256SUMS`; the latest feed reports version 0.1.16 with `arm64` hardware requirements, the v0.1.16 DMG URL and an Ed25519 signature. Build remains ad-hoc signed and not Apple-notarized (DIST-02). An installed-app update from 0.1.15 and the UI-17 Mac checks were not exercised.

### EDIT-22 own comments in the margin and on branches — 2026-11-15
The writer's own comments share the margin list with Ask Matilde threads through `MarginItem.items` (passage order; stale reviews and dismissed threads drop out; hidden and unwritten comments only show while being written). Opening a comment card or narrow-window marker scrolls its passage into view and marks it without moving the caret. `Workspace.branch` copies the source's comments (new ids, same ranges and context, re-anchored against the branch text) in the branching transaction; hidden comments stay hidden, archived and empty ones are skipped. New `UserCommentListTests` cover listing, the store data path (edit, detach/undo, archive, delete), branch anchors, independence and the hidden-comment edge case.

Linux sandbox without Swift: code reading and Python tests (8 passed). CI on PR #11 (run 43731447219, macOS-15, head `16658fa`) passed: 133 Swift tests (one opt-in skip; the 6 new ones included), app build, signature and packaging checks. Live Mac UI not checked: card scroll-to-passage, branch copies appearing after the curl, light/dark highlight, ⇧⌘K/context menu and relaunch persistence.

### 2026-11-15 — Note switching, note cycling and body placeholder (EDIT-25, EDIT-26, UI-18)
Root cause of the switch jump, from code reading: `MarkdownEditor.Coordinator.load` replaced the text but left the clip view at the previous note's offset, then restored the new note's saved cursor and scroll in a `DispatchQueue.main.asyncAfter(0.1)` block, so for about 100 ms the new note was drawn at the old offset before jumping. Two smaller contributors: `CommentMarginColumn` animated the column's re-centering (0.22 s) whenever the old and new notes differed in having comments, and the hosted title/goal header only re-measured on the next editor layout. Fix: switches now land at the top (cursor 0, scroll 0) synchronously inside the SwiftUI update when the editor is already on screen; focus, toolbar title and readiness follow on the next run-loop turn. The first mount keeps the delayed path. Launch restores the session position and a new branch keeps its inherited position (`AppModel.restoresPositionID`). The margin column doesn't animate on a draft change, and `WritingHeaderView` re-lays out the editor when SwiftUI invalidates its size. Shortcuts: ⌃⌘↓ Next Note and ⌃⌘↑ Previous Note in the Writing menu, using `SidebarOrder.visible`, the same function that builds the sidebar. The body placeholder “Start writing…” is drawn with Core Text at the empty first line's baseline.

Linux sandbox without Swift: code reading only; `python3 -m unittest discover -s scripts/tests` passed. New XCTests: `NoteNavigationTests` (visible order across folders/collapse/search, wrapping, top-landing rule, placeholder rule) and `NoteLandingEditorTests` (a hosted editor scrolled to 1500 pt lands at 0 on the first SwiftUI update after a switch, well inside the old 100 ms delay; a restored position lands immediately and stays; the placeholder shows only for an empty body, is not part of the text or undo, hides during marked text, and shares the typed text's first baseline and left edge). CI (macOS-15, run 43731902487 on PR #12): 133 Swift tests passed (one opt-in skip, 0 warnings), including the new tests; app build, signature and packaging checks passed.

Not verified on a Mac: the switch looking still in practice (including from a scrolled note, notes with and without margin comments, and long wrapping titles), ⌃⌘↑/↓ with focus in the editor, title, goal and sidebar (including during IME composition), menu display, sidebar scrolling to the selected row, and the placeholder's look in light and dark mode at several text sizes.

### 2026-11-15 — Alternative app icons (UI-19)
Four alternatives beside the current icon, drawn as SVG in `assets/app-icons/`: Leather, Neon, Blueprint and Chalk. A fifth, Gold Foil, was removed at the owner’s request before merge; a stored `gold-foil` value resolves to the default Matilde icon (`testRemovedGoldFoilChoiceFallsBackToMatilde`). Redrawn after owner feedback that the first set (Nib, Caret, Typewriter, Midnight, Paper Plane) looked bad: every alternative now keeps the default icon's exact layout and changes only colour, material and texture. The body was fitted to the alpha mask of `assets/AppIcon.png` (continuous-corner 870 × 861 at (77, 83), corner 210; IoU 0.999 at 1024 px), and the tilde was traced from the copper original (a fitted centre line with a variable width, IoU 0.97 against its colour mask), so all five share one silhouette and position. `scripts/app-icons.py` renders them with cairosvg (the default is resized from `assets/AppIcon.png`) to 512-px PNGs in `Sources/Matilde/Resources/AppIcons`, copied by `Package.swift` into the resource bundle that `scripts/build-app.sh` already ships; output is byte-identical on re-runs. The contact sheet [`docs/app-icons.png`](app-icons.png) shows each choice at 1024 (half size), 128, 32 and 16 px (and 32/16 enlarged 4×) on light and dark backgrounds; all read at 32 px; at 16 px each is told apart by colour, and the tilde stays visible (faintest on Leather, where it is debossed rather than raised).

Switching approach, chosen after comparing three options:
- `NSApplication.applicationIconImage` (chosen): changes the Dock tile, ⌘-Tab and alert icons while Matilde runs, needs no file writes and leaves the signed bundle untouched; re-applied in `applicationDidFinishLaunching`. Limitation: Finder, Launchpad and the Dock show the bundle's default while Matilde is not running, and the Dock briefly shows the default during launch.
- `NSWorkspace.setIcon(_:forFile:)` on the app bundle (rejected): writes an `Icon\r` file and a Finder-info extended attribute into the bundle root. Unsealed content in a signed bundle's root fails `codesign --verify --strict` (the check `build-app.sh` and CI run) and can make Gatekeeper treat the app as modified; it needs write access to `/Applications`, and every Sparkle update replaces the bundle, dropping the custom icon until re-applied. Not worth the risk with ad-hoc signing.
- `NSDockTilePlugIn` (deferred): a separately built and signed plug-in in `Contents/PlugIns` that the Dock loads to draw the tile when the app is not running. It would make the choice visible in the Dock at all times, but adds a second bundle target that SwiftPM doesn't build, a Dock-process plug-in to sign inside out, and still wouldn't change Finder. Possible follow-up if the owner wants the Dock to keep the icon after quitting.

Linux sandbox without Swift: `python3 -m unittest discover -s scripts/tests` passed (new `test_app_icons.py`: default first and unique names, each SVG is vector, outlined, with the default icon's body and title/description; all alternatives share one body, tilde and spine path, one 512 × 512 RGBA PNG per choice and no strays, titles match the Swift enum, `Package.swift` and CI bundle checks). New XCTests in `AppIconTests` (every choice loads from the bundle at 512 px with transparent corners, preference round trip, empty/unknown/mis-cased/non-string/missing values fall back to the default) run only in CI. Not verified on a Mac: the picker's look in light and dark, the Dock and ⌘-Tab icon changing immediately, re-application after relaunch, and VoiceOver labels.

### AI-14 comment thread chat polish — 2026-11-15
Composer text/button alignment (24-point line box and button, 3-point line spacing), divider replaced by a paper gradient over a gradient-masked material with the thread scrolling underneath and a bottom inset, “Matilde” speaker label only where the speaker changes, right-aligned user bubbles (80% max width), 348-point cards/popovers narrowing to 280 before the editor minimum, and stick-to-bottom streaming. Root cause of the scroll bug: `threadView` called `ScrollViewReader.scrollTo(…, anchor: .bottom)` on every `streamingReply` change and every message-count change with no regard for the reader's position, and the card's height spring re-ran for every new line. Return handling (`ComposerReturn`: ↩/⌘↩ send, ⇧/⌥/⌃↩ newline at the caret via the field editor, nothing while an IME is composing) in the reply and both note composers. New `ThreadChatTests` (follow decision, speaker labels, Return decision) and a card-width test in `MarginLayoutTests`.

Linux sandbox without Swift: code reading and Python tests (8 passed). CI on PR #13 (run 43732696295, macOS-15, after fixing one wrong test expectation from the first run) passed: 139 Swift tests (one opt-in skip), app build, signature and packaging checks. Live Mac UI not checked: ⇧↩/⌥↩ newline vs ↩ send and IME (e.g. Japanese) confirmation, composer centring at one and several lines, fade/blur look in light and dark, bubble width, scrolling up during a streamed reply and resuming at the end, card width at several window sizes and the narrow fallback.

### 2026-11-15 — Slash menu contrast, density and placement (UI-24)
Surface is white in light mode and an elevated gray (0.195) above the dark paper (0.13), with a 0.75-point 13% hairline and two shadow layers (1.5-point contact, 14-point diffuse). Rows are 28 points, section headers 22 points at 10.5 points; width 236. Placement is a pure function in screen coordinates: above when the full unfiltered menu (capped at 352 + insets) fits between the `/` line and the top of the visible editor area (editor visible rect intersected with the screen's visible frame), else below; if neither side fits, the roomier side. `SlashMenuPositioner` stores the side on open and resets on dismiss or a new `/`, so filtering never flips it; the anchor is the `/` location, keeping the bottom (above) or top (below) edge fixed.

Linux sandbox without Swift: code reading only; `SlashMenuLayoutTests` (6 tests: prefer above, below only when the full menu cannot fit, roomier side fallback with clamping, horizontal clamping, fixed bottom edge while filtering, no flip until reset). CI on PR #17 (run 43737198384, macOS-15, after fixing one wrong test expectation from the first run, merged with main) passed: 173 Swift tests (one skipped), app build and packaging checks. Live light/dark and near-top/near-bottom checks on a Mac remain open.

### 2026-11-15 — No window top bar (UI-20)
Hid the title bar and toolbar; moved the sidebar toggle beside the floating traffic lights and the document actions into a floating top-right cluster that fades while typing. Added `WindowChromeTests` (fade state, jitter threshold, hover pinning, focus loss, Command-shortcut classification, toggle/control placement). Built and tested only through CI (macOS-15); the Linux worker sandbox has no Swift toolchain. No live UI inspection yet.

Manual Mac checklist (disposable workspace under `build/`):
- No title text, divider or toolbar background; sidebar and canvas reach the top edge in light and dark mode.
- Traffic lights over the sidebar with the toggle vertically centered beside them; search field clear of them. Collapsed sidebar: lights and toggle over the canvas without covering the header or text.
- Cluster: new document, board/return, Ask Matilde click and its menu, Stash selected state, document menu (including Compare Side by Side) all work; ⌘N, ⌘0, ⇧⌘A, ⇧⌘J, ⌘\ and the Writing menu unchanged.
- Typing in the editor fades the cluster and the floating toggle; moving the pointer, hovering the area, clicking, Escape/Tab out of the editor or switching apps brings them back. Typing in title/goal/search does not hide them. Reduce Motion switches without animating.
- Dragging the top band of the sidebar, canvas and comparison pane moves the window; double-click follows System Settings › Desktop & Dock; board panning still works; scrolling with the pointer at the top edge scrolls the editor.
- Scrolled text fades out under the controls; comment cards, stash (stops below the band), draft tray, board zoom controls, comparison controls, sheets and Settings window look right.
- Full screen: toggle moves to the leading edge, controls stay usable when the menu bar reveals; exit restores positions. Restored scroll positions still land correctly.

### AI-15 unread margin threads and UI-23 card motion — 2026-11-15
Unread state lives on `ReviewComment.unread` (optional, encoded only when set) inside the existing `writing_reviews` JSON payload, so no schema change and nothing in the Markdown. `WritingReviewModel.start` marks new suggestions unread; a completed reply marks its thread unread unless it is the margin's open thread (`openThreadID`, set by the pane's `selected` through `threadOpened`); `markRead` clears every copy of a carried thread. Card motion is in `WritingReviewPane`: `MarginCardMotion` transitions, a glide window keyed to changes in the set of placed cards, a per-note layer identity, and a short stagger after a note switch.

Linux sandbox without Swift: code reading only. CI on PR #16 (run 43735618259, macOS-15, head `2f1549b`) compiled and passed all 7 new `UnreadThreadTests`. The first attempt failed only the unrelated, timing-sensitive `SpellCheckingTests.testCorrectionReportedInsideEditingBatchDoesNotLayOutMidEdit`. The rerun passed: 153 Swift tests (one opt-in skip), app build, signature and packaging checks. Not checked on a Mac: how the dot and muted previews look in light and dark mode, the dot scaling out on open, a reply arriving after closing, the hover hand-off to the archive button, the narrow-marker dot, the feel of the entry and exit springs and neighbour glide, no lag while scrolling or typing, the note-switch stagger next to EDIT-25, and the fade-only path with Reduce Motion. The checklist is on PR #16.

### UI-25 scroll the whole page, margin cards included — 2026-11-15
Owner report: margin cards stacked below the end of the text could not be reached, and scrolling over the comment column (cards or gaps) did nothing. Cause: cards are a SwiftUI overlay positioned in viewport coordinates over the whole writing space, while the editor's `NSScrollView` covers only the centered text column, and its document view (the `NSTextView`) is sized to the text alone. Gestures over the overlay or the side padding land on the SwiftUI hosting view, whose responder chain never reaches the editor's scroll view.

Fix, keeping cards where they are and adding two small pieces rather than moving SwiftUI cards into the AppKit document view (which would mean re-hosting the cards, their popovers, focus and #16's transitions inside `NSTextView`):
- Scroll room: the anchor probe also reports anchor tops in the editor's document coordinates (scroll-invariant). The pane stacks cards there with the same function it uses for display (`MarginScroll.stack`, now shared) and passes the bottom of the natural stack to the editor, which sets `minSize.height` to `MarginScroll.contentHeight` and calls `sizeToFit()`; the text view stays at least as tall as its text. The text container keeps its unbounded height, so layout, UTF-16 ranges and undo are untouched. The open card's pull into the viewport is excluded, so the height doesn't follow scrolling. When cards leave, `MarginScroll.retainedHeight` keeps room that is on screen and releases it as it scrolls out of view, so removing a card at the bottom never snaps the page.
- Scroll forwarding: `MarginScrollForwarding`, a hit-test-transparent view behind the cards, watches scroll-wheel events in its window. At the start of a gesture (or each legacy wheel event) it hit-tests the pointer; inside the writing space, with no scroll view between the hit view and the pane (so not over the editor, a long thread or the stash, and outside `StashEventBoundary`), the whole gesture including momentum goes to the editor's `NSScrollView.scrollWheel(with:)`. Off while the board, a branch curl or a board flight is showing.

Linux sandbox without Swift: code reading only. CI on PR #19 (run 43737372439, macOS-15, head `69fc849`) passed: 174 Swift tests (one opt-in skip) including the 7 new `MarginScrollTests` (stacking, cards bottom, content height, retained room), app build, signature and packaging checks. Not checked on a Mac: trackpad and mouse scrolling over cards, gaps and padding (momentum, elastic edges, gestures crossing from text to cards), reaching the lowest card, caret placement in the added room, archiving the bottom card while at the bottom, nested scrolling in long threads and the stash, and narrow-window markers. The checklist is on PR #19.

### EDIT-30 vertical rhythm for editor blocks — 2026-11-15
Before, from code reading: every line got the same 16-point `paragraphSpacing` (lists 6, quotes 3) and no space above, so a heading sat as close to the paragraph before it as any other paragraph (9 pt line spacing + 16 = 25 pt), H1 → H2 likewise; one typed blank line added a full body line on top (≈44 pt); code lines inside fences kept the 16-point paragraph spacing and body line spacing. Heading sizes 27/23/21/20/19/19 had no common ratio.

Now `Typography` holds one scale (em of the writing size): headings 1.125 modular sizes, line spacing ≤ 0.2 × heading size, before/after H1 2.0/0.6, H2 1.6/0.5, H3 1.3/0.4, H4–H6 1.1/0.3; paragraphs/lists/quotes/code/images 0.85 after; dividers 1.0 around; inside a run, list items 0.3, quote lines 0.15, code 0 (code line spacing 0.2 em). `MarkdownStyler` classifies each line, then sets the gap as `paragraphSpacing` on the earlier block (later blocks keep their line tops, so caret, highlight, image and margin-card geometry anchored to the line top or baseline is unchanged). Collapsing: same-kind runs use their inner value, otherwise max(earlier after, later before). Empty lines are exactly one body line with no spacing and are subtracted from the gap. No `paragraphSpacingBefore` is used, so the first block starts directly under the header. `styleImages` keeps the styler's spacing and only sets the image line height.

Linux sandbox without Swift: code reading; `python3 -m unittest discover -s scripts/tests` passed. CI on PR #18 (run 43736901753, macOS-15, head `5560147`, main merged in) passed: 165 Swift tests (one opt-in skip), including the 9 new `TypographyTests`, plus app build, signature and packaging checks; the only compiler warnings are the existing ones in `AppIcon.swift`. After merging main again (window chrome, #15), run 43737204640 (head `6a758d7`) passed 175 Swift tests (one opt-in skip) and the build checks on its second attempt; the first attempt failed once in `SpellCheckingTests.testCorrectionReportedInsideEditingBatchDoesNotLayOutMidEdit`, where the model had not yet received a deferred change after the test's 10 ms run-loop wait (a timing assertion; the same test passed in run 43736901753 and in the rerun). Not checked on a Mac: the look of the rhythm in the welcome document and a disposable test document (heading spacing above and below, H1 → H2, heading with and without a blank line above), caret and placeholder placement, comment highlights and margin cards on and after headings, top landing on note switch, comparison and stash panes, text size 16/26 and line spacing 2/12, images, dividers, checkboxes and quote bars, light and dark mode.

### AI-16 suggestions in the thread's timeline — 2026-11-15
Root cause: `reviewRun` drew `comment.suggestion.replacement` above the message loop, and a reply's rewrite overwrote that single field, so every rewrite was pinned above the conversation. Now `ThreadTimeline.items(for:)` merges messages and rewrites in chronological order. Each reply's rewrite is stored on its message (`ReviewMessage.replacement`), the current one is identified by `ReviewComment.rewriteMessageID`, and the review's own rewrite is kept in `initialReplacement` after a reply replaces it. All of this lives in the `writing_reviews` JSON payload, with no schema change. When `reviewHistory` loads older threads, `attachLegacyRewrite()` places an Ask Matilde rewrite after the latest reply; review threads keep theirs first. `BottomFollower.observe` now reports growth past the end while following, so `threadView` keeps a newly laid-out rewrite in view.

Linux sandbox without Swift: code reading only. CI on PR #20 (run 43738541371, macOS-15, before merging main) passed all 7 new `ThreadTimelineTests` and 187 Swift tests in total (one opt-in skip), plus the app build, signature and packaging checks. A rerun after merging main (with #18 and #19) is recorded on the PR. Not checked on a Mac: the inline and muted look in light and dark mode, a rewrite arriving in view at the end of a long thread, staying put after scrolling up, Accept on the current rewrite and its undo, the disabled state after editing the passage, the narrow popover and Review history order, and opening threads saved by the current release. The checklist is on PR #20.

### 2026-11-15 — Sidebar toggle in the traffic lights' row (UI-26)
Owner screenshots of 0.1.17: toggle at about (62, 31) pt below the traffic lights (≈10 pt), over the search field with the sidebar open; top-right actions at ≈31 pt. The overlays and the HSplitView panes were inside the 28-point top safe area of the hidden title bar, so every control was offset by it. Fixed by laying all chrome out from the window's top edge (`.ignoresSafeArea(.container, edges: .top)` on the sidebar, split panes and every chrome overlay) and measuring one row from the zoom button's real frame in content-view coordinates. Chose this over an `NSTitlebarAccessoryViewController`: an accessory would hide with the title bar in full screen, sit outside the SwiftUI fade state, and change how SwiftUI's hidden title bar lays out, while the existing overlays only needed correct coordinates. Added `WindowChromeTests` cases for the row (zoom-frame mapping, centring, full-screen fallback, implausible frames, band height). Built and tested only through CI (macOS-15); the Linux worker sandbox has no Swift toolchain. No live UI inspection.

Manual Mac checklist (disposable workspace under `build/`):
- Sidebar open: toggle beside the zoom button, centred on the traffic lights; search field starts just below that row with nothing overlapping.
- Sidebar collapsed (⌘\ and the button): toggle stays in exactly the same spot; top-right actions share the row on both states.
- Typing in the editor fades the top-right actions (and the toggle while the sidebar is collapsed); pointer movement brings them back.
- Dragging the top band over the sidebar, canvas and comparison pane moves the window; the toggle and actions stay clickable.
- Full screen: toggle at the leading edge in the same row; exiting restores it beside the traffic lights. Writing header, board, stash and comparison controls look right after moving up 28 points.

### 0.1.17 release preparation — 2026-11-15
Owner explicitly requested a new release. Latest tag was `v0.1.16`, so this is 0.1.17. No pull requests were open. `git log v0.1.16..origin/main` contains the 0.1.16 publication record, #10 (docs) and #11–#20: own comments in the margin and branch copies (EDIT-22), top landing on note switch, note cycling and body placeholder (EDIT-25, UI-18, EDIT-26), comment thread chat polish (AI-14), alternative app icons (UI-19), no window top bar (UI-20), unread dots and card motion (AI-15, UI-23), slash menu (UI-24), type and spacing scale (EDIT-30), whole-page scrolling (UI-25) and rewrites in the thread timeline (AI-16). CI on main head `a5f29e9` (run 43739420593, macOS-15) passed. Version set to 0.1.17 with release notes. The live Mac UI checks listed for those items remain open.

### 0.1.17 publication — 2026-11-15
Release workflow run 43739704261 (dispatched on `main` at `f778cb2`, version 0.1.17) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing, the artifact upload (`Matilde-0.1.17`, 6.5 MB) and publication; its only annotation is GitHub's macOS arm64 queue-time notice. GitHub Release `v0.1.17` (tag on `f778cb2`) is published as latest with `Matilde.dmg`, `appcast.xml` and `SHA256SUMS`; the latest feed reports version 0.1.17 with `arm64` hardware requirements, the v0.1.17 DMG URL and an Ed25519 signature. Build remains ad-hoc signed and not Apple-notarized (DIST-02). An installed-app update from 0.1.16 and the Mac UI checks for the included items were not exercised.

### 0.1.18 release preparation — 2026-11-15
Owner explicitly requested a new release ("merge it and do new release"). Latest tag was `v0.1.17`, so this is 0.1.18. No other pull requests were open. `git log v0.1.17..origin/main` contains the 0.1.17 publication record and #21: the sidebar toggle in the traffic lights' row (UI-26). CI on main head `ea6767e` (run 43755536504, macOS-15) passed. Version set to 0.1.18 with release notes. The live Mac UI checks for UI-26 remain open.

### 0.1.18 publication — 2026-11-15
Release workflow run 43755942031 (dispatched on `main` at `581acfa`, version 0.1.18) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing, the artifact upload (`Matilde-0.1.18`, 6.6 MB) and publication; its only annotation is GitHub's macOS arm64 queue-time notice. GitHub Release `v0.1.18` (tag on `581acfa`) is published as latest with `Matilde.dmg`, `appcast.xml` and `SHA256SUMS`; the latest feed reports version 0.1.18 with `arm64` hardware requirements, the v0.1.18 DMG URL and an Ed25519 signature. Build remains ad-hoc signed and not Apple-notarized (DIST-02). An installed-app update from 0.1.17 and the Mac UI checks for UI-26 were not exercised.

### 2026-11-15 — Header with breathing room (UI-28)
Owner screenshots of 0.1.18: traffic lights about 7 points from the left and top, the sidebar toggle 10 points past the zoom button, top-right actions about 8 points from the right edge. `WindowChrome` now has one set of header constants: 52-point row (centre 26), 18-point horizontal inset, 24-point controls at top 14. `WindowChromeModel.placeTrafficLights()` resizes the title-bar container (the close button's superview's superview) to 52 points and moves the three buttons to x = 18 + n × (system stride), centred on the row, then measures the zoom button to place the collapsed toggle. It runs on attach, resize, end of live resize, key/main changes, screen changes, full-screen enter/exit (plus one run-loop turn later) and whenever the close button's frame changes; it skips full screen and only writes frames that differ, guarded against re-entry. An empty unified `NSToolbar` would give a similar inset natively, but it changes the window (larger corner radius and toolbar glass/scroll-edge treatment on macOS 26, a toolbar strip in full screen, SwiftUI managing the window's toolbar), against UI-20's invisible top bar. Sidebar open: toggle frame ends at the search field's right edge (x 204–232). Collapsed: 14 points past the zoom button (x 86 with default buttons); full screen collapsed: x 14 (icon at 18). Top-right cluster: trailing padding 11 + backing 3 + icon margin 4 = 18. Search starts at 52; canvas header at 68 (16 below the row; 0.1.18 started at 57); comparison drag band 52 with controls at an 18-point inset; canvas fade 64 points; the stash leaves 52 points.

Linux sandbox without Swift: code reading only; `python3 -m unittest discover -s scripts/tests` passed. CI on PR #22 (run 43761773069, macOS-15, head `58290d3`) passed: 201 Swift tests (one opt-in skip), including the rewritten `WindowChromeTests`, plus app build, signature and packaging checks. Not checked on a Mac:
- Traffic lights at the new position on launch, after resize, live resize, switching windows/apps, entering and exiting full screen, and moving to another display; no flicker back to the default spot; hover glyphs (×, −, +) on all three buttons; clicking them.
- Sidebar open: toggle at the sidebar's trailing edge, aligned with the search field's right edge and centred with the traffic lights. Collapsed: toggle past the traffic lights with comfortable spacing; toggling with ⌘\ and the button.
- Top-right icons 18 points from the right edge, same row; comments chevron and the more menu clickable.
- Dragging the header band over the sidebar, canvas and comparison pane moves the window; double-click zooms; the toggle and actions stay clickable inside the taller title-bar area.
- Typing fades the top-right actions (and the collapsed toggle); pointer movement brings them back.
- Full screen: traffic lights hidden, controls keep the row and insets. Writing header, board, stash and comparison look right with the taller header.

### 2026-11-15 — Sidebar right-click actions (UI-27)
Context menus on note rows, folder rows and the empty sidebar list (`MatildeApp.swift`), backed by `SidebarActions.swift` (pure helpers plus `Workspace.duplicate`, `renameFolder`, `trashFolder`) and `AppModel` actions. Existing paths reused: `moveNote` for Move To, `trashDraft` for note Trash (now picking the next note in sidebar order as a last fallback instead of the alphabetically first draft), `newDocument(in:)`, the rename/goal/new-folder sheets, `compare`, `branch`. Folder Trash and rename run in one SQLite transaction with the filesystem step last and roll back on failure; nothing is deleted permanently.

Linux sandbox without Swift: code reading only. CI on PR #23 (run 43761841332, macOS-15, head `8f30297`) passed: 209 Swift tests (one opt-in skip) including all 10 new `SidebarActionsTests` (folder contents/count, move targets, neighbour choice, rename paths, folder Trash with reconnection and rollback, folder rename, duplicate), app build and packaging checks. The menus themselves are unverified on a Mac.

Manual Mac checklist (disposable workspace under `build/`):
- Right-click a note: every item listed in UI-27 appears; ⇧⌘B and ⌘⌫ show only on the open note. Branch Draft on another note opens it and plays the curl of that note's page.
- Duplicate opens `Title copy`; Rename… and Writing Goal… open the sheet for that note; Move To moves the family (with images) and expands the destination.
- Show in Finder, Copy Markdown (unsaved text of the open note included) and Copy Path work.
- Move to Trash on the open note opens its parent or neighbour; the file is in the macOS Trash.
- Right-click a folder: New Document creates `Untitled` inside and expands it; New Folder… preselects it as parent; Rename… keeps notes, branches, goals and the open note; Expand/Collapse All; Move to Trash… shows “It contains N notes.”, cancel leaves everything, confirm moves the folder to the macOS Trash and opens a neighbour if the open note was inside.
- Right-click empty space below the list: New Document (in Documents) and New Folder…; right-clicking a row still shows the row's menu, not the empty-area one.
- Board visible or comparison open while trashing/renaming: no stale sheets or panes.

### 0.1.19 release preparation — 2026-11-15
Owner explicitly requested a new release ("yes merge both and do new release"). Latest tag was `v0.1.18`, so this is 0.1.19. #22 (UI-28, header breathing room; CI run 43762078596 green on head `ceb076f`) merged as `a87a849`; #23 (UI-27, sidebar right-click actions; main merged in, CI run 43762831874 green on head `c9783b4`) merged as `2fd324a`. No other pull requests were open. `git log v0.1.18..origin/main` contains the 0.1.18 publication record, #22 and #23. CI on main head `2fd324a` (run 43763175564, macOS-15) passed. Version set to 0.1.19 with release notes. The live Mac UI checks for UI-27 and UI-28 remain open.

### 0.1.19 publication — 2026-11-15
Release workflow run 43763556088 (dispatched on `main` at `d379cce`, version 0.1.19) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing, the artifact upload and publication. GitHub Release `v0.1.19` (tag on `d379cce`) is published as latest with `Matilde.dmg` (6.7 MB), `appcast.xml` and `SHA256SUMS`; the latest feed reports version 0.1.19 with `arm64` hardware requirements, the v0.1.19 DMG URL and an Ed25519 signature. Build remains ad-hoc signed and not Apple-notarized (DIST-02). An installed-app update from 0.1.18 and the Mac UI checks for UI-27 and UI-28 were not exercised.

### 2026-11-18 — Live database moved to Application Support (SYNC-01)
`WorkspaceStore.swift` resolves the database at `~/Library/Application Support/Matilde/workspaces/<workspaceID>/workspace.sqlite` (the app is not sandboxed; `FileManager`'s Application Support URL would follow a container if it were) and migrates `.matilde/workspace.sqlite` once when a workspace opens: SQLite backup API into `workspace.sqlite.incoming-<uuid>`, `journal_mode = DELETE`, reopen read-only, `PRAGMA integrity_check`, per-table row counts equal to the source, no sidecar files left, rename into place, then rename the old file to `workspace.sqlite.migrated` (timestamped name if that exists). `.matilde/workspace.json` holds the ID; `store.json` in the store records the last root path to tell a moved workspace (path gone: keep the store) from a copy (original still has the same ID: new ID, store seeded from the original). Markdown, snapshots and stashes stay in the workspace.

Linux sandbox without Swift: code reading only; the backup/WAL sequence was rehearsed with Python's `sqlite3` (same SQLite backup API). CI on PR #24 (run 44392857546, macOS-15, head `7f12b7d`) passed: 222 Swift tests (one opt-in skip) including the 13 `WorkspaceStoreTests`, app build, signature and packaging. The first CI run found that Apple's SQLite keeps empty `-wal`/`-shm` files after closing a WAL database (persistent WAL); the copy is now checked to be in rollback mode and those files are removed before the rename, and the old file's sidecars are renamed with it.

Manual Mac checklist (use a copy of a real workspace or a disposable one under `build/`, not the owner's only copy):
- Before updating, note a draft with private comments, an Ask Matilde thread (read and unread) and a goal. Quit 0.1.19 normally.
- Launch the new build with that workspace: everything opens as before; the comments, threads, unread dots, goals, branches and the last open draft are all there.
- In Finder (⇧⌘. to show hidden files): `.matilde/workspace.sqlite` is gone, `.matilde/workspace.sqlite.migrated` and `.matilde/workspace.json` exist; `~/Library/Application Support/Matilde/workspaces/<id from workspace.json>/workspace.sqlite` exists.
- Add a comment, quit, relaunch: it survives, and no new `.matilde/workspace.sqlite` appears.
- Optional: choose a brand-new empty folder as workspace: no `workspace.sqlite` is created inside it.
- Optional: duplicate a workspace folder in Finder and open the copy: same comments at first; a comment added in the copy does not appear in the original.

### 2026-11-18 — End-to-end encryption keys and recovery (SYNC-06)
Core module `Sources/Matilde/SyncCrypto/` (no UI, no networking), spec in [sync-encryption.md](sync-encryption.md). Linux sandbox: the module and its tests were compiled and run against swift-crypto (Swift 6.0.3, same API as CryptoKit): 47 tests passed; the Swift output matches the independent Python vectors (`scripts/sync-vectors.py`) byte for byte. CI on PR #27 (run 44408025841, macOS-15, head `b84a15b`) passed: 258 Swift tests (one opt-in skip), including all 47 new ones and the real Keychain round trip under a throwaway service, plus app build, signature and packaging.

Nothing to check visually yet. Once SYNC-07 adds the UI: the recovery key is shown once, printing works, the last-group confirmation accepts lowercase and rejects a wrong group, and Keychain Access shows "Matilde — sync encryption key" as this-device-only.

### 2026-11-18 — Portable sync record model (SYNC-02)
Builds on SYNC-01 (PR #24). `SyncRecord.swift`, `SyncPayloads.swift` and `SyncLedger.swift` add the record model of `docs/sync-model.md`: HLCs, deterministic ids, canonical fields, change tracking with per-field clocks, tombstones and the outbox in two new tables (`sync_records`, `sync_meta`). The app's tables and the Markdown files are only read. Tracking runs when a workspace opens (this is also the migration of existing data) and when Matilde quits; failures are logged with counts and the error type only and never block opening or quitting.

Linux sandbox: the Foundation-only sync files, `Workspace`, `WorkspaceStore` and the storage parts of the comment, review and stash files were compiled with a Linux Swift 6.0.3 toolchain (CryptoKit replaced by a test-only SHA shim, checked against Python's `uuid5`), and the 19 new tests (`SyncRecordTests`, `SyncLedgerTests`) passed there. CI on PR #28 (run 44408401984, macOS-15, head `497732b`) passed: 241 Swift tests (one opt-in skip) including the 19 new ones, app build, signature and packaging.

Manual Mac checklist (disposable workspace under `build/` or a copy, not the only copy of real writing):
- Open an existing workspace with drafts, branches, comments, an Ask Matilde thread and a stash: everything looks and behaves as before; opening is not noticeably slower.
- The Markdown files are unchanged (`git status`/Finder dates on a copy, or compare checksums before and after).
- `sqlite3 ~/Library/Application\ Support/Matilde/workspaces/<id>/workspace.sqlite "SELECT type, count(*), sum(deleted) FROM sync_records GROUP BY type"` lists records for each kind of data; running Matilde again and quitting without edits leaves the HLCs unchanged (`SELECT max(hlc) FROM sync_records`).
- Delete a private comment, quit: its row has `deleted = 1`. Trash a draft, quit: its draft and body rows are tombstones and a `type = 10` row appears.
- Console.app (filter "Matilde sync"): only counts, never titles, paths or text.

### 2026-11-18 — Client sync engine (SYNC-07)
`Sources/Matilde/Sync/`, design in [sync-client.md](sync-client.md). Linux sandbox (Swift 6.0.3, swift-crypto in place of CryptoKit): the engine, codec, merge rules and HTTPS transport with `SyncEngineTests` (25, one macOS-only compression skip) and `SyncTransportTests` (8) passed; `WorkspaceSyncStore` with the real `Workspace` and SQLite and `WorkspaceSyncTests` (7) passed with the AppKit-only review types stubbed. Performance with the fake server (Linux debug build): 1000 drafts (2000 records) pushed in 0.19 s with 11 requests, pulled and applied on a second workspace in 0.20 s with 4 requests, no work on the main thread. `SyncCenter` and the Settings tab are AppKit and were only built by CI. CI on PR #29 (run 44421385889, macOS-15, head `10bb4fc`) passed: 335 Swift tests (one opt-in skip) including the 40 new ones and DEFLATE compression, app build, signature and packaging.

Manual Mac checklist (disposable workspaces under `build/`, never the only copy of real writing; the staging server must be deployed):
- Point the app at staging: quit Matilde, run `defaults write app.matilde.local sync.server staging`, launch `build/Matilde.app` (a `bash scripts/build-app.sh` build is a release build, so the Server picker is hidden; afterwards `defaults delete app.matilde.local sync.server`). Settings → Sync: off by default, no Server picker. Turn it on, enter an email, Send Code, enter the mailed code, Sign In.
- First device: the recovery key appears once; Copy works; a wrong last group is refused, the right one in lowercase is accepted. Keychain Access shows "Matilde — sync encryption key" and a `app.matilde.local.sync.session` item, both this-device-only.
- Second workspace on the same Mac (`--workspace build/sync-b`, a different macOS user, or a second Mac): sign in with the same email, enter the recovery key. A wrong key shows an error; the right one starts syncing and the first workspace's drafts appear.
- Edit a draft on A; within ~10 s it changes on B. Rename a draft and move it to a folder; create a folder; branch a draft; set a goal: all arrive.
- Move a draft to Trash on A: on B it goes to the macOS Trash, not deleted.
- Conflict: disconnect B from the network (or quit A), edit the same paragraph on both, reconnect: one keeps the server text, a branch "Title — from <Mac name>" holds the other text; nothing is lost.
- Paste an image on A: it shows on B. Add a private comment and an Ask Matilde thread with a reply on A: both appear on B; reading the thread on B clears its unread dot on A.
- Offline: turn Wi-Fi off, edit on A (status says Offline), turn it back on: the edits arrive without Sync Now.
- Typing stays smooth during a sync of a large workspace; quitting does not wait.
- Sign Out on B: sign-in appears again; signing back in asks for the recovery key. Turn Sync off: no more network traffic (Little Snitch or `nettop`).
- Console.app, filter "Matilde sync": only counts, status codes and error codes, never titles, paths, emails, codes or text.

### 0.1.20 release preparation — 2026-11-21
Owner explicitly requested the release ("ship 0.1.20") after checking a main build on a copy of a real workspace on their Mac. Latest tag was `v0.1.19`, so this is 0.1.20. `git log v0.1.19..origin/main` contains the 0.1.19 publication record, #24 (SYNC-01), #25 (sync server, SYNC-04/05, `server/` only), #26 (AI-17), #27 (SYNC-06 crypto core, no UI) and #28 (SYNC-02). Nothing in the app connects to the sync server and there is no sync UI. CI on main head `cb8c73b` (run 44416165232, macOS-15) passed; the earlier CI run on #25's merge (44411985479) failed in Test and was superseded by the green runs after #26–#28. PR #29 (SYNC-07, draft) is not included. Version set to 0.1.20 with release notes. The owner's Mac check covered SYNC-01, SYNC-02 and AI-17, now Done in ROADMAP.

### 0.1.20 publication — 2026-11-21
Release workflow run 44929534158 (dispatched on `main` at `a6a5be1`, version 0.1.20) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing, the artifact upload and publication. GitHub Release `v0.1.20` (tag on `a6a5be1`) is published as latest with `Matilde.dmg` (6.9 MB), `appcast.xml` and `SHA256SUMS`; the latest feed reports version 0.1.20 with `arm64` hardware requirements, the v0.1.20 DMG URL and an Ed25519 signature, and the downloaded DMG matches `SHA256SUMS`. Build remains ad-hoc signed and not Apple-notarized (DIST-02). An installed-app Sparkle update from 0.1.19 was not exercised.

### 0.2.0 release preparation — 2026-11-21
Owner explicitly requested merging PR #29 and releasing without a manual Mac test of sync ("i don't wanna test, lets just do it"). Latest tag was `v0.1.20`; sync is a new feature, so this is 0.2.0 (release-version.py compares versions as integer tuples, the Sparkle feed and `CFBundleVersion` use `0.2.0`, which Sparkle orders after `0.1.20`; the sync header sends build 200). `git log v0.1.20..origin/main` contains the 0.1.20 publication record and #29 (SYNC-07, client sync engine with Settings → Sync, off by default; release builds use only the production server). PR #29 was brought up to date by merging `main` (conflict in this file only, both entries kept); CI on its final head `b817b09` (run 44930195106, macOS-15) passed, then it was squash-merged as `9e39e65`. No server change; `https://sync.matilde.page/v1/health` answered `{"ok":true,"api":"v1"}`. **Sync was not checked on a Mac**: the SYNC-07 checklist above is still open, and SYNC-04 to SYNC-07 stay In progress. Release notes present sync as a beta and suggest a backup before turning it on.

### 0.2.0 publication — 2026-11-21
Release notes were reworded in `97a18ac` before dispatch (GitHub strips `<Mac name>` as HTML). Release workflow run 44930578890 (dispatched on `main` at `97a18ac`, version 0.2.0) passed version/signing validation, tests, arm64 build, DMG packaging, Sparkle archive/feed signing, the artifact upload and publication. GitHub Release `v0.2.0` (tag on `97a18ac`) is published as latest with `Matilde.dmg` (7.2 MB), `appcast.xml` and `SHA256SUMS`; the latest feed reports version 0.2.0 with `arm64` hardware requirements, the v0.2.0 DMG URL and an Ed25519 signature, and the downloaded DMG matches `SHA256SUMS`. CI on main at `97a18ac` (run 44930572465) passed; the runs on `9e39e65` and `974b225` were cancelled as superseded. Build remains ad-hoc signed and not Apple-notarized (DIST-02). Not exercised: an installed-app Sparkle update from 0.1.20, and sync itself on a Mac (SYNC-07 checklist open).

### 0.2.1 release preparation — 2026-11-21
Owner asked in the project chat to merge PR #38 and cut a new desktop release once the queued follow-ups were done. The latest tag was `v0.2.0`. The Mac changes are a new setup flow and UI for the existing sync beta, with no format or protocol change, so this is 0.2.1. `git log v0.2.0..origin/main` holds the 0.2.0 publication record, #30 to #33 and #35 to #37 (server deploys, monorepo layout, landing page, pnpm workspace, MatildeKit package with no change in behaviour) and #38. For the Mac, #38 brings the guided sync setup sheet in Settings → Sync: intro, email, a six-box code input (`OneTimeCodeEditor`), recovery key with Copy, Save… and Print…, unlock with an iCloud Keychain fill, and status, account and devices once sync is on. CI on #38's final head `50367b5` (run 44953441874, macOS-15) passed, including the icon packaging check after the sync UI moved to Tabler icons. It was squash-merged as `92ee5a0`. **Not checked on a Mac:** the setup sheet's look, code AutoFill/paste and whether the iCloud Keychain copy works in an ad-hoc signed build. IOS-12 and SYNC-07 stay In progress.


### 0.2.1 publication — 2026-11-21
The first Release run, 44953945610 (dispatched on `main` at `d22adc4`), failed in Test on the timing-sensitive `SpellCheckingTests.testCorrectionReportedInsideEditingBatchDoesNotLayOutMidEdit`. That test also flaked on PR #38 and main CI. It now waits for the editor's deferred change report instead of a fixed 10 ms (`75bd1a3`); no app code changed and no tag was created. Release run 44954145410 (dispatched on `main` at `75bd1a3`, version 0.2.1) passed version/signing validation, tests, the arm64 build, DMG packaging, Sparkle archive/feed signing, the artifact upload and publication. GitHub Release `v0.2.1` (tag on `75bd1a3`) is published as latest with `Matilde.dmg` (7.6 MB), `appcast.xml` and `SHA256SUMS`. The feed reports version 0.2.1 (minimum macOS 14.0), the v0.2.1 DMG URL and an Ed25519 signature, and the downloaded DMG matches `SHA256SUMS`. The build is still ad-hoc signed and not Apple-notarized (DIST-02). Not exercised: an installed-app Sparkle update from 0.2.0 and the new sync setup sheet on a Mac.
