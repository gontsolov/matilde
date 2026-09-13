# Product and architecture notes

These notes record the architecture discussion. Agreed decisions are distinguished from proposals and unresolved details.

## Product direction

Build an excellent native macOS writing experience. AI is a quiet supporting feature, not the center of the interface.

The visual direction is Japanese paper: restrained, tactile, and carefully detailed, with a feeling of writing something that lasts. Bear is the closest editor reference, alongside Obsidian, Raycast Notes, and Notion. The canvas inspiration is [Flora](https://flora.ai/); its specific interactions have not yet been studied.

## Agreed decisions

### Native interface and editor

- Build the application in SwiftUI.
- Use an AppKit text editor embedded in SwiftUI for editing control; SwiftUI handles the surrounding interface and canvas. The exact text system implementation remains open.
- Render Markdown live while writing.
- Keep formatting symbols hidden during normal editing. The user specifically wants fewer visible symbols than Bear, with a minimal document-like experience.
- Support typing Markdown shortcuts to apply formatting. Exact selection, cursor, and syntax-reveal behavior still needs design.
- V1 formatting includes headings, bold, italic, links, bulleted and numbered lists, checklists, blockquotes, and code blocks.
- Tables and embedded images are deferred beyond v1.
- V1 layout: a collapsible folder/document sidebar, a centered editor, and a small branch switcher beside the document title.
- Include a focus mode that hides the sidebar for uninterrupted writing.
- Keep the interface minimal and native: standard macOS toolbar, system typography for controls and titles, serif writing text, short functional labels, and no slogans or empty-goal prompts. Show an existing goal below the title; edit or add goals through the document actions menu.
- Use bundled Newsreader from Google Fonts for writing and Markdown headings, including bold and italic. Controls and document titles retain native system typography. Font files and the SIL Open Font License ship with the app; no runtime font download is needed.

### Workspace and persistence

- Matilde manages one workspace folder, with subfolders for organizing files.
- First-launch onboarding offers “Start writing”, which creates or reuses `Documents/Matilde` automatically and opens document creation when the workspace is empty. “Choose another folder” is a secondary option. An existing default workspace is reused without replacing its files.
- Restore the last workspace, active draft, cursor/scroll position, and sidebar/focus state on subsequent launches.
- Store writing as ordinary `.md` files, accessible outside Matilde.
- Use a local SQLite database for document goals, comments, branch relationships, canvas positions, and related metadata.
- Store the local SQLite database and immutable branch snapshots in a hidden `.matilde` folder inside the workspace, so whole-workspace copies and backups include the writing, goals, and branch history together.
- Persist application content and state locally. File identity, snapshot format, and coordination between file and database writes remain to be designed.
- Autosave after a short typing pause and save when switching drafts. Show a subtle “Saved” indicator after a successful save, and support `⌘S` for an immediate save. The exact autosave delay remains an implementation detail.
- Reload files when they change externally. The user prefers this simple approach for now; advanced conflict handling is deferred. Automatic conflict branches were proposed but are not part of the agreed v1 scope. Behavior when external changes overlap unsaved edits remains unresolved.

### Starting a document

- The user supplies a filename and can optionally describe what they want to write or achieve.
- The writing goal is saved as document context and will later be supplied to the LLM.
- The user then enters a clean editor.
- The writing goal is optional and editable later, so users can start writing immediately.
- New branches inherit the source branch's goal and can change it independently afterward.

### Branches

- Branching creates an alternate draft; both the original and the new branch remain independently editable.
- Capture an immutable snapshot at the branching point to preserve where the drafts diverged.
- Each branch has its own text and comment history.
- Each branch is a separate Markdown file beside its source, for example `Essay.md` and `Essay — Alternative.md`. Matilde groups related drafts while each file stays accessible in Finder. Filename collision handling remains an implementation detail.
- Branching captures the snapshot, creates an automatically named draft (for example `Essay — Alternative 1.md`), and immediately opens it for editing. Users can manually rename drafts later. V1 automatic names do not require AI.
- AI-assisted naming and renaming are planned for the deferred AI phase.
- Show relationships between drafts on a visual canvas.
- Snapshots live inside the workspace's hidden `.matilde` folder. Snapshot format and treatment of existing comments when branching remain open.

## First usable build: agreed scope

Target the user's own Mac first. Distribution to other users and broader macOS compatibility are deferred until the writing experience feels right. Inspect the local macOS and development tools before selecting the deployment target.

Start with the focused live-rendering Markdown editor and a simple branch switcher. Both branches remain editable, with an immutable snapshot captured when branching. Persist branch relationships from the start so the later canvas can use the same underlying model.

The zoomable canvas and all AI functionality are deferred to later phases. The initial priority is getting the writing and branch-switching experience right. The formatting scope is agreed above; detailed editing interactions and storage mechanics still need to be resolved.

## Canvas: deferred, direction to refine

The user wants to zoom out to see multiple drafts, then zoom into one to write. Settling on a draft should lock into a focused editing experience. Leaving that focus by zooming out or moving sideways should have resistance, so ordinary editing does not accidentally navigate away.

The canvas is planned for a later phase. Its layout, gestures, transition thresholds, and accessibility alternatives have not been agreed yet.

## AI: documented, deferred from initial implementation

The user explicitly requested documenting AI behavior without building the AI parts yet. Do not implement API integration, automatic review, or AI suggestion generation in the initial build.

Future direction:

- Connect to Langdock using a user-provided API key. API details have not yet been investigated.
- Use the document's writing goal as context.
- Review the active branch after a meaningful edit followed by approximately 30 seconds of inactivity. This is the agreed starting behavior; what counts as a meaningful edit remains to be defined.
- Place comments quietly in the margin without stealing focus.
- Offer Google Docs-style comment threads that users can review, reply to, accept, and remove.
- Never change text through AI suggestions without user acceptance.
- Include a pause control and a manual “Review now” action.
- Suggest follow-up directions for the writing.
- Support AI-assisted automatic draft naming and later renaming. Exact triggers and user controls remain to be designed.
- Persist comments and their history locally.

Before implementing AI, resolve comment anchoring as text changes, stale reviews, suggestion acceptance semantics, credential storage, and the exact content sent to Langdock.

## Next architecture questions

Resolve these one at a time, recording decisions here:

1. How should file identity, snapshots, database recovery, and detailed editing interactions evolve beyond the first build?

The first build's high-level scope is agreed above; continue resolving its implementation details through the architecture discussion.
