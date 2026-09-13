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
