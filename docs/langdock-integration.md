# Langdock writing guidance

Updated 2026-09-14. Initial manual integration implemented at the owner's request. Backlog: AI-01 through AI-04 in ROADMAP.md.

## Available experience

In Settings → Connections, save a Langdock API key in Keychain, select the API address and region, load available models and choose a compatible chat model. No model is selected automatically. Writing assist is always visible beside the active writing area. Review starts a manual request; the title menu opens saved history. In compact layouts the title menu also contains the review action.

Manual review uses the active writing goal and returns zero to three comments about clarity, structure or support, with optional replacements. Floating cards overlay the writing surface 16 points beyond the actual text column, beside their TextKit passages, and follow scrolling. They reserve no sidebar width or editor layout space. The stash opens above them. Compact previews expand on selection; selected passages receive a temporary highlight and nearby cards stack without overlap. Smaller windows use compact comment buttons with popovers. The Writing assist header provides Review and saved history, without an icon or dismiss control. Clicking a quote selects its source. Replacements require acceptance and remain undoable through the native editor. Earlier runs remain accessible in local history.

Reviews are stored in the workspace SQLite database, scoped to draft identity. New branches start independent histories. A hash includes title, goal and body. Any change cancels an in-flight request. Body edits move unaffected UTF-16 anchors; edits overlapping a quote invalidate that comment. Title or goal changes invalidate the review context. Saved source/revision data allows anchors to be checked again on reopen; late responses cannot apply to another draft. Multiple disjoint external edits are conservatively treated as one changed span. Exact quotes plus prefix/suffix must identify an unambiguous, nonoverlapping UTF-16 range. Acceptance rechecks the revision and source.

## API and context

The native URLSession client uses Bearer authentication with `POST /openai/{region}/v1/chat/completions` and `GET /openai/{region}/v1/models`. Default address is `https://api.langdock.com`; EU and US are selectable. Dedicated installations can include `/api/public` in their base URL. HTTPS is required and redirects are rejected to avoid forwarding credentials. [Langdock OpenAI-compatible endpoint](https://docs.langdock.com/en/developer/completion-api/openai).

The request uses JSON mode (`response_format: {"type":"json_object"}`), not strict API-enforced JSON Schema. Local decoding checks completion status, bounded fields, comment count and anchors before presenting results. JSON-mode review replies have been verified with the configured model; compatibility across other models remains unverified. Requests have timeouts, cancellation, a bounded response size and one bounded retry on rate limiting. Upstream response bodies and keys are excluded from errors.

Reviews supply the active draft title, goal and body. Replies also supply the relevant comment, the new question and up to twelve prior thread messages, with the same image/path redaction. Stash, other drafts and image files are excluded; Markdown image references and recognized absolute local paths are scrubbed. This is a defined context boundary, not a general-purpose secret detector. The writing is treated as untrusted review material. Credentials remain in Keychain and, after successful access, in a process-only cache shared by requests; save/remove refreshes that cache. No credential is written to settings or disk outside Keychain. Ad-hoc rebuilt binaries can still require authorization on first access because their designated requirements change; stable Developer ID signing is a separate follow-up. reviews remain locally persisted. The Connections screen explains what is sent.

## Automatic reviews and replies

After meaningful body or goal changes and thirty seconds without further draft edits, Writing assist reviews the active draft if the app is active, no board/transition/dialog is open, and a model plus session-authorized key are available. Saving the key or making a manual request authorizes the current process session; automatic reviews never read Keychain interactively. Opening a draft alone does not send it. Formatting-only changes are ignored; identical attempted revisions are not retried automatically. Pause/resume is available from the Writing assist title menu and persists across launches. Draft edits/switches and pause cancel pending work. Existing open threads carry into the next review, and unchanged previously reviewed quotes are suppressed.

Expanded comments have a reply field. Successful replies are saved with the comment and may update its optional rewrite. They never modify the draft until Accept rewrite is chosen. Messages appear and persist immediately with pending delivery state; the thread shows Thinking and Cancel while waiting. Failed or cancelled requests keep the question and offer Retry without duplicating it. Interrupted pending requests recover as failed on reopen; stale responses are discarded. New messages scroll into view. User and assistant messages have subtly different surfaces. The reply composer stays fixed below the scrolling transcript, and expanded cards shorten when focus leaves the conversation, preserving the thread. There is no Dismiss control. Cards animate their height with Reduce Motion support, show hover/focused styling, and autofocus the input every time they open. Source snapshots and threads are local SQLite metadata; new branches have independent histories.

## Asking about selected text

Select body text and click the small Ask Writing assist action, use the right-click menu, or press Shift-Command-A. The anchored thread opens immediately with its composer focused; no API request happens until Send. Exact selection ranges support repeated phrases and Unicode. Selecting an existing open thread’s exact range reopens it. These threads share review history, acceptance and cancellation behavior; automatic reviews preserve them.

## Verification and remaining work

86 Swift tests passed with one existing opt-in skip; app assembly and code-signature verification passed. Tests cover Unicode anchor movement, overlap invalidation, legacy decoding, persisted replies, cancellation after edits, independent histories, the automatic debounce/pause/deduplication flow and Unicode line differences, in addition to existing transport and native acceptance/undo checks.

A disposable thirty-section workspace under `build/assist-ui` was used to verify compact scrollable popovers, expanded card separation and long-document scrolling. A real Langdock reply using the configured key/model returned an explanation and optional rewrite, persisted across relaunch, and left the draft unchanged. The original workspace and active draft were restored. A transient computer-use connection timeout was resolved by reconnecting; a stack sample showed the app's main run loop was responsive.

Dark-mode comment contrast, extended-use review quality/cost and a separately observed timed automatic request remain verification follow-ups. Deterministic timer tests pass. Provider retention terms and broad model compatibility have not been assessed. Follow-up directions and automatic naming remain separate roadmap items.


### Streaming chat replies (2026-09-15)
Chat replies request `stream: true` on the existing OpenAI-compatible endpoint, retaining JSON mode. SSE deltas are bounded, cancellation-aware, and coalesced to approximately 25 UI updates per second. The prompt requests the answer field first; a safe partial-string decoder displays text while holding incomplete escapes/surrogate pairs. If a model orders fields differently, the answer appears on completion. Reviews remain non-streaming.

Partial answer text is transient. Only a complete stop/DONE response passing the existing JSON/size/refusal checks is persisted or supplies a new accepted rewrite. Interrupted requests retain the failed user question and Retry behavior. No raw JSON or incomplete replacement is shown. The transcript uses plain messages with differently colored role labels and a sticky composer.

Verified with synthetic streaming transport (including incremental updates, JSON mode), escape/Unicode, refusal, truncation and size-limit tests. Live provider streaming has not yet been exercised; no owner writing was submitted during these checks.
Reference: https://docs.langdock.com/en/developer/completion-api/openai
