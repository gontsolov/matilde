# Markdown editing behaviour (EDIT-31)

How Matilde's editors respond to Backspace, Delete, Return, Tab, typing and paste in Markdown. The rules live once, in MatildeKit (`packages/MatildeKit/Sources/MatildeKit/Editor/`), as pure functions from text and selection to an edit. The Mac editor (`WritingTextView`) and the iPhone editor (`NoteUITextView`) call them and fall back to the system's own behaviour when a rule returns nothing, so ordinary typing keeps native undo, spelling and input methods.

Tests: `packages/MatildeKit/Tests/MatildeKitTests/MarkdownEditingTests.swift` writes every rule as text plus selection in, text plus selection out (`|` is the caret, `«…»` a selection). The Mac wiring (undo, caret, indentation) is covered by `apps/macos/Tests/MatildeTests/MarkdownEditingIntegrationTests.swift`; the iPhone rendering by `apps/ios/MatildeTests/EditorTests.swift`.

## Rules

### Backspace

| Before | After | Rule |
| --- | --- | --- |
| `# |Title` | `|Title` | At the start of a heading's text the `#` marks go; it becomes a paragraph. |
| `## A|` | `|` | Deleting a heading's last character removes its marks too: no stray `#`. The same when a selection empties the heading. |
| `- |item` | `|item` | At the start of a top-level item's text the marker (bullet, number or checkbox) goes. |
| `1. a`, `2. |b`, `3. c` | `1. a`, `|b`, `2. c` | Following items are renumbered. |
| `- a`, `  - |b` | `- a`, `- |b` | A nested item moves out one level first. |
| `> > |q` | `> |q` | At the start of a quote's text one level of `>` goes. |
| `**b**|` (Mac) | `**|**` → `|` | With hidden markers, Backspace steps over them; deleting a span's last visible character removes the whole span, so no `****` is left. On iPhone, where the marks are visible, they are deleted one by one. |
| `(|)` | `|` | An empty bracket pair goes together. |

Emoji and other composed characters are always deleted whole.

### Delete (forward)

At the end of a line, Delete joins the next line's text without its marker (`- a|`, `- b` → `- a|b`). Hidden markers are stepped over as with Backspace.

### Return

| Before | After | Rule |
| --- | --- | --- |
| `- a|` | `- a`, `- |` | Lists continue with the same bullet. |
| `9. a|` | `9. a`, `10. |` | Numbers count on; following items are renumbered. Numbers too large to count on stay the same. |
| `- [x] a|` | `- [x] a`, `- [ ] |` | Checkboxes continue unchecked. |
| `- ab|cd` | `- ab`, `- |cd` | Return in the middle splits the item. |
| `- a`, `- |` | `- a`, `|` | Return on an empty top-level item ends the list. |
| `- a`, `  - |` | `- a`, `- |` | Return on an empty nested item moves it out one level. |
| `> q|` | `> q`, `> |` | Quotes continue; Return on an empty quote line ends one level. |
| `# |Title` | ``, `# |Title` | At the start of a heading's text a line opens above; the heading stays whole. |
| `|- a` | ``, `|- a` | Before the marker, Return is plain. |

Inside fenced code, and with a selection spanning lines, Return is plain. Shift-Return (Mac) adds a line inside the item, indented to its text, without a new marker.

### Tab and Shift-Tab

| Before | After | Rule |
| --- | --- | --- |
| `1. a`, `2. |` | `1. a`, `   1. |` | Tab anywhere in an item nests it under the item above. A nested numbered run starts at 1. |
| `- a`, `- |b` | `- a`, `  - |b` | Bullets and checkboxes nest the same way, lined up with the parent's text. |
| | | An item's own children move with it. With a selection, every selected item nests. |
| `- |a` (first item) | unchanged | The first item can't nest; Tab does nothing rather than typing a tab. |
| `   1. |` | `2. |` | Shift-Tab moves an item out one level and renumbers both levels. Later siblings become its children. |
| top-level item | unchanged | Shift-Tab at the top level does nothing. |

Outside lists, Tab types a tab as before. On iPhone, the formatting bar's indent and outdent buttons and a hardware keyboard's Tab and Shift-Tab do the same.

### Typing

- With a selection on one line, typing `*`, `_`, `` ` ``, `[` or `(` wraps it instead of replacing it.
- `(` and `[` before a space, punctuation or the line end add the closing bracket; typing `)` or `]` right before that closing bracket steps over it.
- A space after `[ ]`, `[x]` or `[]` at the start of a line (or after a bullet) makes a checkbox, `- [ ] `.
- Inside code nothing is paired or converted.

### Paste

- Windows and old Mac line endings become plain line breaks.
- Pasting list items, quote lines or a heading into an empty item or quote line replaces its empty marker (`- ` plus `- a` gives `- a`, not `- - a`); further pasted lines keep the item's indentation and quote.

### Display

- Nested items are indented by depth (Mac: 1.4 em per level; iPhone: 24 pt), not by the raw number of spaces, which are hidden. Wrapped lines align with the item's text.
- The caret never stops on hidden characters. On the Mac, arrow keys step over hidden `**`, `#`, link destinations and indentation in one press, and moving left from a heading's first character goes to the end of the line above. Clicking or moving up and down to the start of such a line puts the caret after the hidden marks. On iPhone the caret is kept out of a heading's marks and a nested item's indentation.

### Undo

Every rule is one undo step, separate from the typing before it. Undo brings back exactly the text and selection from before the key press.

## Research

How other editors behave, and what we took:

- **CodeMirror 6** (`@codemirror/lang-markdown`): `insertNewlineContinueMarkup` continues list and quote markup, splits items, renumbers following items and ends the list on an empty item (outdenting a nested one first). `deleteMarkupBackward` removes a marker at the start of its line's text and outdents nested items. Our Backspace and Return rules follow these two commands closely, including renumbering.
- **ProseMirror / Tiptap / Milkdown**: input rules (`[ ] ` → task, `1. ` → list) with `undoInputRule` on Backspace, `splitListItem` on Enter, `sinkListItem`/`liftListItem` on Tab/Shift-Tab, and Backspace at a block's start lifting it out (`joinBackward`, `liftEmptyBlock`). We copied the Tab/Shift-Tab model, including that later siblings become children of an outdented item.
- **Obsidian live preview** (CodeMirror 6 based): hides markers except near the caret, Tab/Shift-Tab indent list items, ordered sub-lists restart at 1, Return on an empty item outdents then exits.
- **Bear**: hides syntax, Tab indents list items (the owner's reference for nesting), Backspace at an empty item removes its marker, Return on an empty item ends the list.
- **Typora**: Backspace at a heading's start turns it into a paragraph; Return at a heading's start keeps the heading whole; Tab/Shift-Tab in lists.
- **Notion / Craft**: block editors; Backspace at a block's start turns it into plain text before merging it with the block above, Tab nests under the previous block, and an empty bullet plus Return ends the list. We follow the same "first remove the formatting, then merge" order.
- **iA Writer / Ulysses**: keep Markdown visible, continue lists on Return, end them on an empty item; iA Writer auto-pairs brackets but not emphasis marks.

## Decisions

- **No automatic pairing of `*`, `_` or `` ` ``.** In prose these are often single (lists, footnotes, apostrophe-like use), and on the Mac a pair would be hidden immediately, leaving an invisible span. A selection is wrapped instead. Brackets pair only before whitespace or punctuation.
- **Nested numbered runs restart at 1**; a top-level run keeps its first number. The whole run is renumbered after every change, so numbers never drift.
- **Composed text is left alone.** No rule runs while an input method has marked (uncommitted) text.
- **Hidden indentation.** The stored Markdown keeps its spaces (3 under a `1. `, 2 under a `- `, matching the parent's text column), so the file reads correctly anywhere.
