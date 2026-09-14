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
