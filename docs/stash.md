# Stash: a pocket for the writing around the writing

Status: in progress; implementation authorized on 2026-09-14. Owner requested documentation on 2026-09-14 and confirmed family-shared ownership, polished open/close motion, and hands-on onboarding. Canonical backlog: STASH-01 in [ROADMAP](../ROADMAP.md).

## Intent

Keep bullet points, loose thoughts, cut passages, and reference links close to a document without making them separate sheets on the canvas. Open the stash quickly, write directly in it, then tuck it away and resume the draft at the same position.

The owner's supplied reference is a small corner note emerging over the current app. Borrow the sense of something tucked just out of view, not its appearance or an OS-wide hot corner. This is supporting material, not another draft, the document's goal, or an AI conversation.

## Proposed interaction

- A small paper lip at the bottom-right of the **writing area**, outside the text column—not the display corner or sidebar. It stays available when the sidebar is hidden and does not move with canvas panning.
- Hover reveals a little more of the lip and the label “Stash.” It never steals keyboard focus or opens the full editor by itself. A short dwell and a forgiving hit area should prevent flicker; timings need hands-on tuning.
- Click opens a warm-paper panel upward from that corner. It overlays the writing surface without reflowing the document or becoming a canvas sheet. Starting size: roughly 420 × 360 points, clamped to the available window; final dimensions are provisional.
- Open by click or a keyboard command, then type immediately at the stash's remembered caret. Offer a menu action as well; choose a conflict-free shortcut during implementation, not an unverified binding now.
- The panel stays open when the pointer leaves. Clicking the document lets you work in the draft with the stash still visible. Escape while the stash owns focus, its close control, or the toggle command tucks it away and restores the previous writing caret/scroll.
- Keep controls minimal: “Stash” and close. One Markdown editing surface with bullets, checklists, emphasis, and links. No collection browser, tabs, artificial note cards, or required title in the first version.
- Empty state is simply a focusable writing area with a short placeholder. Opening an empty stash does not create a file. Once populated, the tucked lip can look slightly fuller; no counts or notification badges.
- Brief eased motion, approximately 180–220 ms as a starting point; Reduce Motion uses no sliding. No large curl or animation that delays typing.

## Ownership: agreed

One stash per draft family. The owner explicitly chose shared notes across branches. Creating a branch does not copy the stash; every branch opens the same content. An edit made from one branch is visible from the others. The panel omits the ownership description at the owner’s request (2026-09-14); sharing remains explained in the welcome exercise.

Branches refer to the same stable family ID, not the current root filename. Renaming or trashing the root must not disconnect the stash. Deleting one draft must never delete shared notes. If all drafts disappear, retain the stash for recovery; do not silently garbage-collect it. Define recovery access before shipping. Independent/copied stashes are outside the agreed first version.

## Open/close choreography

Polished motion is part of the requested feature, not optional follow-up work. The exact tuning below is proposed, to be checked hands-on.

- Tucked → peek: the small paper edge lifts a few points on hover, with a restrained shadow. Leaving reverses the peek without opening the editor or changing focus.
- Peek/tucked → open: the panel emerges upward from the same bottom-right anchor, decelerating into place. Use a short translation and masked reveal, with only a tiny scale change if needed; no full-screen travel, rubbery bounce, or exaggerated page curl. Target roughly 220 ms.
- Open → tucked: reverse the spatial path into the paper lip, with the shadow reducing as it settles. Target roughly 180 ms; do not merely fade the panel out in place.
- Keep text at its final layout width throughout the reveal so lines do not rewrap during motion. The real editable surface must be ready when opening; early typing cannot disappear into an animation placeholder.
- Rapid toggles reverse from the current presentation, not snap to an endpoint or queue animations. A hover exit must never dismiss an explicitly opened panel.
- Closing preserves the buffer and flushes saving; restore focus exactly once. A save failure must not strand invisible unsaved notes. Family switches and canvas transitions must not let stale animation completions refocus the wrong editor.
- Respect Reduce Motion with an immediate transition or brief opacity change, preserving identical focus/save behavior. No slide or scale in that mode.

## Onboarding: try the stash, not just read about it

Ship the welcome-document update with the working feature, not before it. Add this concise section after “Try another direction” in `WelcomeDocument.text`:

> ## Keep the loose bits
> Open Stash in the bottom-right corner. Add a bullet with an idea you want to try, then tuck it away. Branch this page and open Stash again—your notes come with you. Every draft shares the same stash; nothing extra lands on the canvas.

Keep the existing final branching invitation, so readers can do this as part of the same exercise. Start with an empty stash and let the user add their own first bullet; no extra tutorial document, seeded junk, popup, or mandatory tour. Opening an empty stash alone still creates no file.

Preserve the current welcome-document safety rules: new/recreated welcome documents use the new copy, existing edited welcome pages are never overwritten. Verify the exercise in a fresh disposable workspace, including writing a bullet, closing/reopening, branching, seeing that bullet in the shared stash, and editing it from either draft. For the owner's existing workspace, do not rewrite their welcome document just to demonstrate the feature.

## Focus, saving, and canvas boundaries

- Maintain independent text, undo history, cursor, scroll position, and debounced save state for the stash. Never route stash typing through the draft's body-save callback or update the draft's edited timestamp for stash-only changes.
- Flush on closing the panel, switching owner/workspace, quitting, and Command-S. On a failed save, keep the buffer and recovery path; do not dismiss or replace unsaved notes silently.
- Switching between branches in the same family keeps the shared stash and its caret. Switching to another family flushes and closes the panel, so notes never appear to belong to the wrong document.
- Canvas can expose the same fixed-corner stash for its current family. It never receives a sheet, connector, pin position, or canvas-search result. A transition tucks away the panel after saving; the small entry point remains accessible once the transition settles.
- Scrolls and clicks inside the panel must not pan/zoom the canvas. Escape first handles active native text interactions, then closes the stash; it should not also navigate the canvas.
- Keep a keyboard-accessible toggle with VoiceOver labels and proper focus restoration. Hover is enhancement, not the only discovery/access path.

## Local storage proposal

Use an ordinary UTF-8 Markdown sidecar under `.matilde/stashes/<family-id>.md`, keyed by the stable family identity. This keeps it out of the current visible-file scan while including it in whole-workspace backups. Keep metadata/position separately in SQLite. Validate paths and symlinks, save atomically, and apply external-edit recovery rather than overwriting dirty buffers.

Opening a stash should not mutate the main Markdown file, goal, snapshots, or branch relationships. The hidden location is not encryption; notes remain local, readable files. Copying only a main `.md` file does not carry its stash—provide an explicit way to reveal/copy the stash without adding explanatory chrome to the editor.

Do not automatically convert or remove existing scratch documents. A later explicit “Move to Stash” action could help, but needs collision, append, asset, and undo semantics. For now users can copy their notes without risking the originals.

## Focused first version and later possibilities

First version: one shared stash per draft family, corner entry point, polished reversible open/close interaction, editable Markdown panel, reliable save/reopen, keyboard access, hands-on welcome-document exercise, and no canvas clutter. Resolve orphan recovery before shipping.

Later, separately approved: send selected passages to the stash, insert stash text into the draft, resize/pin the panel, multiple snippets, image/attachment support with safe relative asset paths. No drag-to-move or automatic deletion until undo is dependable. Stash content must not be included in future AI requests without an explicit context/privacy decision.

## Verification before calling it finished

Use disposable workspaces. Check bullet typing, Unicode, links, undo/redo, rapid open/close, focus return, Command-S, quit/relaunch, switching during pending saves, external changes, and simulated write failures. Confirm ownership behavior after branching, rename, root deletion, and workspace reopen. Verify no stash content appears on the canvas/sidebar, no writing timestamp changes, no accidental hot-corner activation, and no gesture leakage. Inspect narrow windows, sidebar hidden, Reduce Motion, and keyboard/VoiceOver access. These are future acceptance checks, not completed tests.


## Implementation and verification — 2026-09-14

The first implementation is built locally. `Stash.swift` contains validated sidecar storage, independent save/buffer/position state, and the mounted corner editor. The editor stays mounted while tucked, retaining native undo across close/reopen. Position uses family-keyed SQLite state. Hover peeks after 100 ms; opening/closing use a reversible spring (320 ms response, 0.82 damping). Reduce Motion disables the slide. The Writing menu exposes ⇧⌘J, Reveal Stash, Show All Stashes, and Reload Stash from Disk.

Orphan recovery is file-based: Show All Stashes opens the retained sidecars even when no documents remain. Files use stable family UUID names. External clean changes reload; overlapping unsaved changes block saving, closing, switching and quitting. Reload Stash from Disk first preserves local changes in a unique recovery Markdown file alongside the stashes and reveals it in Finder, then loads the external version. Failed writes retain the buffer. There is no automatic deletion of orphan or recovery files.

Verification: 54 Swift tests, one opt-in Keychain skip, no failures; production app assembly/signature checks passed. Tests cover Unicode storage, family sharing after rename/root removal, orphan retention, hidden scan behavior, unchanged writing timestamps, positions, external conflicts, symbolic links, and failed-save buffer retention. A disposable `build/stash-ui` workspace verified the new welcome exercise, bullet continuation, Unicode paste, undo/redo, keyboard/Escape focus return, branching/shared notes, canvas access, scroll/close behavior, rapid toggles, and quit/relaunch. Original workspace restored; no owner writing used as test content.

Remaining acceptance work is STASH-02: physical trackpad isolation, Reduce Motion, narrow-window/sidebar-hidden layout, full VoiceOver use, close/open reversal feel, and the complete conflict/recovery UI flow. These remain verification gaps, not established failures. No release was published.


2026-09-14 visual refinement: removed the ownership subtitle and aligned header, writing, and placeholder to a uniform 16-point inset. Native line-fragment padding is zero only in the stash; the main writing editor retains its existing spacing.


2026-09-14 interaction refinement: panel height increased from 300 to 360 points, clamped to the available height. Removed the bottom outer inset and bottom corner radii so the panel meets the window edge. Open/close now uses a fast, lightly underdamped spring; hover uses a 200 ms spring. Reduce Motion still disables both animations.


2026-09-14 pull-tab refinement: replaced the document icon and asymmetric lip with a compact Stash tag and small grip, 4-point upper corners and square lower corners. The tab is inset an extra 16 points from the right so the native window corner cannot round its base. Open/close spring response is now 320 ms with 0.82 damping; hover uses 260 ms with 0.84 damping.


2026-09-14 typography refinement: stash width increased to 420 points. Stash and document editors share the Writing line-spacing preference, defaulting to 9 points. Lists no longer override line spacing; list-item paragraph spacing is 6 points. Continuation lines use measured rendered prefix widths for bullet, numbered, and checklist markers. Explicit saved spacing preferences remain respected.


2026-09-14 adaptive-height refinement: starts at 420 points tall and grows to fit native text layout plus header and text insets. Maximum height is the writing-area height minus a 16-point top margin; content scrolls after reaching that limit. Width stays fixed at up to 420 points. Shrinking text can reduce height back toward the minimum. Native layout reports include the trailing empty line and update after wrapping/width changes.
