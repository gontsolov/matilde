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
