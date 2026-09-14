# Langdock writing guidance

Updated 2026-09-14. Initial manual integration implemented at the owner's request. Backlog: AI-01 through AI-04 in ROADMAP.md.

## Available experience

In Settings → Connections, save a Langdock API key in Keychain, select the API address and region, load available models and choose a compatible chat model. No model is selected automatically. Writing assist is always visible beside the active writing area. Review starts a manual request; the title menu opens saved history. In compact layouts the title menu also contains the review action.

Manual review uses the active writing goal and returns zero to three comments about clarity, structure or support, with optional replacements. Floating cards overlay the writing surface 16 points beyond the actual text column, beside their TextKit passages, and follow scrolling. They reserve no sidebar width or editor layout space. The stash opens above them. Compact previews expand on selection; selected passages receive a temporary highlight and nearby cards stack without overlap. Smaller windows use compact comment buttons with popovers. The Writing assist header provides Review and saved history, without an icon or dismiss control. Clicking a quote selects its source. Replacements require acceptance and remain undoable through the native editor. Earlier runs remain accessible in local history.

Reviews are stored in the workspace SQLite database, scoped to draft identity. New branches start independent histories. A hash includes title, goal and body. Any change cancels an in-flight review and makes existing suggestions stale; late responses cannot apply to another draft. Exact quotes plus prefix/suffix must identify an unambiguous, nonoverlapping UTF-16 range. Acceptance rechecks the revision and source.

## API and context

The native URLSession client uses Bearer authentication with `POST /openai/{region}/v1/chat/completions` and `GET /openai/{region}/v1/models`. Default address is `https://api.langdock.com`; EU and US are selectable. Dedicated installations can include `/api/public` in their base URL. HTTPS is required and redirects are rejected to avoid forwarding credentials. [Langdock OpenAI-compatible endpoint](https://docs.langdock.com/en/developer/completion-api/openai).

The request uses JSON mode (`response_format: {"type":"json_object"}`), not strict API-enforced JSON Schema. Local decoding checks completion status, bounded fields, comment count and anchors before presenting results. Model support must still be verified live. Requests have timeouts, cancellation, a bounded response size and one bounded retry on rate limiting. Upstream response bodies and keys are excluded from errors.

Only the active draft title, goal and body are supplied. Stash, other drafts and image files are excluded; Markdown image references and recognized absolute local paths are scrubbed. This is a defined context boundary, not a general-purpose secret detector. The writing is treated as untrusted review material. Credentials remain in Keychain; reviews remain locally persisted. The Connections screen explains what is sent.

## Verification and remaining work

76 Swift tests passed with one existing skip, and the app build/signature check passed. Synthetic transport tests cover model discovery, payload construction and redacted authentication errors. Review tests cover Unicode and ambiguous anchors, overlap rejection, malformed/truncated results, persistence, independent branch histories, cancellation on edits/switches, accepted rewrites and undo.

A disposable workspace was used to inspect a saved synthetic review in the running app. Quote navigation, acceptance and Command-Z passed; Connections layout was inspected. The original workspace was restored without editing its writing. No real Langdock request was made: no saved key was configured. Authentication/scopes, available models, JSON-mode compatibility, actual latency, response quality, costs and deployment retention terms remain unverified.

Automatic reviews after roughly 30 seconds of inactivity, pause controls, thread replies, finer anchor movement under edits, follow-up directions and naming remain future increments. Establish live model quality and request cost before enabling automatic review.
