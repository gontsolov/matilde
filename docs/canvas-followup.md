# Follow-up: a board of pinned drafts

Status: implemented. Release build and 12 tests pass. Live checks cover scrolling, editor-to-board transitions, and opening another draft from the board.

## First implementation

- Current document family only, with pinned paper previews and branch connectors.
- `⌘0` or the toolbar board button opens the board. Editor zoom-out pinches continuously move the mounted page after a 3% dead zone, with cubic ease-out toward the board. Releasing at 18% outward travel settles onto the board; smaller or reversed gestures return to writing. Corners round during the transition and meet the board cards' 16-point rounded corners at the current zoom.
- The current page shrinks toward its board position. Clicking another sheet expands it into editing; cursor and scroll positions remain independent.
- Automatic positions are stored in SQLite. New children sit down-right of their source; siblings receive separate rows without moving earlier sheets.
- Drag the board, scroll with two fingers, or use the mouse wheel to pan. Pages lift subtly on hover and use a pointing-hand cursor. Pinch or use +/− to zoom. Fit shows the family; arrow keys move focus, Return opens a sheet, and Escape returns to the active draft.
- Pinching inward beyond 120% opens the sheet under the pointer at gesture start. Zoom keeps that point anchored; starting over empty space does not open a draft. Keyboard selection/Return remain independent. Reduce Motion skips the page-flight animation.
- Board position and zoom are saved per family. The app currently reopens in editor mode; the saved board viewport is reused next time the board opens.
- Only lightweight previews are rendered for visible sheets. Transitions keep the real editor mounted at its full layout size, animate its scale and clipping bounds, and blend into the same card view used on the board. No screenshot cache or approximate editor preview is used.
- Opening flights use a 340 ms easing curve. Outward flights use cubic ease-out over 180–420 ms based on remaining distance. Completion uses animation callbacks. Opening another draft waits for its editor layout and saved scroll position to be ready. Input is held until the flight finishes; Reduce Motion switches directly.

Pinch distance sets a target rather than immediately moving the sheet. An interactive task advances toward it with a 60 ms smoothing time constant and a 5 progress units/sec speed cap, clamping elapsed time to 1/30 sec after stalls. Reversal updates the same target; release stops tracking and settles from the displayed progress. This prevents a large native event from skipping the visible flight. The owner found the initial 160 ms / 1.8-per-second tuning too slow; these faster values retain smoothing without the long tail. Physical trackpad feel remains to be checked in CAN-07.

Continuous editor pinch is implemented. The native event monitor retains the gesture while the page moves away from the pointer; cancellation, keyboard interruption, and window deactivation return it to writing. Reduce Motion retains the release decision without scaling. Board-to-editor navigation still uses the existing settled flight after clicking a sheet or ending board zoom beyond 120%.

Still to verify/refine: physical trackpad delivery and resistance feel (CAN-07), freely dragging individual sheets, and large-family usability. Automated UI tools do not expose native pinch gestures.

## Core experience

The editor and the canvas are two views of one continuous space. Zooming out reveals the current sheet in its place on a board of pinned drafts. Selecting another sheet or zooming into it returns to focused editing, restoring that draft's cursor and scroll position.

The user specifically wants sheets to feel pinned on a board, and the transition to connect naturally to the existing page-tearing branch animation.

## Branching connects the two views

1. The user branches while writing.
2. The current sheet tears away, revealing the new editable draft underneath.
3. The original remains on the board as an independently editable sheet. The new draft has its own nearby position.
4. Zooming out reveals both sheets and their relationship.

The tear should communicate where the previous sheet went. It must not imply that the original was deleted or frozen. Both drafts stay editable; the existing immutable branching snapshot is separate from either live sheet.

## Zoom out to the board

- The focused editor shrinks continuously into its board position, rather than disappearing and being replaced by an unrelated screen.
- Show sheets with their draft titles and recognizable text previews, using the same paper and Newsreader visual language as the editor.
- Indicate that sheets are pinned, with restrained details rather than decorative clutter.
- Place related drafts near one another. Subtle connectors show the branching relationships.
- Preserve spatial orientation: the sheet the user was editing remains identifiable throughout the transition.
- Add resistance around the focused editing zoom level so small or accidental gestures do not eject the user from writing.

## Return to writing

- Clicking a sheet or deliberately zooming into it brings that draft forward into the focused editor.
- Restore its own saved cursor and scroll position.
- Once the sheet settles into editing focus, ordinary typing, selection, and document scrolling work normally.
- Offer an explicit board control and keyboard navigation as alternatives to zoom gestures.
- Respect Reduce Motion with a simpler transition that preserves the same navigation behavior.

## First scope

Start with the current document's draft family: its original and related branches. Keep separate documents in the sidebar. This scope was approved when the user asked to begin the canvas.

Reuse the existing branch identities, relationships, Markdown files, and snapshots. Persist sheet positions and board viewport state in the workspace's `.matilde` SQLite database. Canvas layout must not create extra copies of document content.

AI and any AI-generated content remain outside this follow-up's scope.

## Decisions to resolve when we pick this up

- Exact zoom gesture, thresholds, and resistance; distinguish board navigation from scrolling a document or changing text size.
- Whether users can drag/re-pin sheets immediately, or whether the first layout is automatic.
- How new branches are placed and how the tear direction points toward the original sheet's board position.
- Which preview detail remains readable at each zoom level, including long or empty drafts.
- Whether leaving and reopening the app restores board mode as well as the board viewport.

## Acceptance criteria

- From an open draft, zoom out and visibly follow that same sheet into the board.
- Branch a draft, then see both independently editable sheets on the board with their relationship intact.
- Open another sheet and resume at its saved writing position without losing unsaved work.
- Switch repeatedly between editor and board without changing draft identity or creating duplicate files.
- Reopen the workspace and retain saved sheet positions.
- Small incidental gestures do not leave editing mode; explicit controls and keyboard interaction can perform the same navigation.
- Reduced Motion remains usable, and a large draft family does not require rendering every full document as a live editor.
