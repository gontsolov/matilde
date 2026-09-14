# Langdock writing guidance

Investigated 2026-09-14. This is a proposal for discussion, not an implemented feature or authorization to send writing. Backlog: AI-01 through AI-04 in ROADMAP.md.

## Recommended first experience

Start with a manual **Review now** action that returns at most three useful margin comments about the active draft. Use the writing goal to judge clarity, structure, missing support, and whether the draft achieves its intent. Preserve the author's voice; an empty result is valid when there is nothing worthwhile to flag. A comment may ask a question or suggest a direction, rather than always offering replacement text.

Example using synthetic writing: for a draft announcing a faster export feature, a comment could say “This promises faster exports, but gives no comparison. Could you add a typical before/after time?” Anchor it to the exact claim.

After manual review and anchoring work reliably, add the previously agreed review after roughly 30 seconds of inactivity, plus pause. A proposed meaningful-change rule is changed sentence/paragraph content since the last reviewed revision; cursor movement, autosave, and formatting-only activity should not trigger another review. Debounce and deduplicate suggestions. Follow-up replies, accepted replacements, and naming can follow in separate increments.

## API findings

Langdock provides provider-specific compatible Completion endpoints, with personal API keys or workspace keys granted Completion API scope. This is enough for draft review; the initial design does not need remote agents or a knowledge base. [Completion overview](https://docs.langdock.com/en/developer/completion-api/completion-overview).

A concrete initial adapter can use `POST https://api.langdock.com/openai/eu/v1/chat/completions`, Bearer authentication, and model discovery at `GET /openai/eu/v1/models`. The documented endpoint offers EU and US regions; select the intended region explicitly. Supported models depend on workspace configuration. Structured response support must be tested on the selected model. Handle 429s with bounded backoff and cancellation. [OpenAI-compatible endpoint](https://docs.langdock.com/en/developer/completion-api/openai).

Dedicated installations use a custom host with `/api/public` before the provider path. Langdock blocks browser-origin requests. A native URLSession client with the user's own Keychain credential is the proposed macOS approach; verify this with a synthetic request before committing to it. Never embed a shared application secret. [API introduction](https://docs.langdock.com/en/developer/overview/api-introduction).

No live credential or completion calls were made. Model access, actual latency, response quality, costs, deployment retention terms, and native request compatibility remain unverified. Model choice should follow a small synthetic writing evaluation, not a hardcoded assumption about what the workspace exposes.

## Context and ownership proposal

Send the active draft title, goal, body, and explicit review instruction. Leave the stash, other branches, unrelated files, images, and absolute filesystem paths out by default. For a reply, add only its relevant comment thread. Explain this boundary when the user enables writing assistance; keep request and response bodies out of diagnostic logs. Treat draft text as material to review, never as instructions to override the review contract or request other files.

Keep review history in the local workspace SQLite database. Scope reviews to draft identity and a content revision/hash. For the first version, a newly created branch starts its own review history; its source retains its existing comments. This is a proposed resolution of the previously open branch-history question.

## Implementation shape

- `LangdockClient`: async URLSession transport with Codable requests/responses, cancellation, response-size bounds, model discovery, and redacted errors; use existing APIKeyStore.load only when making a request.
- `ReviewCoordinator`: capture immutable draft identity/content/goal revision; cancel on draft change or new review. Reject late responses for changed revisions. A single in-flight request per draft is sufficient initially.
- `ReviewStore`: persist review runs, comments, replies, status, and anchors transactionally. No Markdown-source rewrites for annotations.
- Native margin presentation: position comments from editor layout, avoid stealing focus, and support dismissal. Use a compact presentation when the window lacks margin space.

Request a bounded typed result: comment kind, exact source quote, surrounding context, explanation, and optional replacement. Validate every result locally. Match quotes against the captured source and convert ranges using the editor's UTF-16 conventions; reject ambiguous or absent matches. Keep exact quote plus prefix/suffix and original range/hash. Shift ranges for edits entirely before the anchor; mark overlapping edits stale rather than silently attaching the comment elsewhere.

Accepted replacements must recheck the current anchor and apply as one native undoable edit. Never apply a suggestion automatically. Do not render or act on partial structured output. A completed validated response is sufficient for the initial review; streaming can be considered later for replies.

## Verification before enabling

Use disposable synthetic writing to check auth failures, missing scopes, model availability, timeouts, rate limits, malformed/truncated responses, repeated quotes, emoji/Unicode, edits during review, switching/branching while requests are pending, persistence/relaunch, and undo after acceptance. Confirm that review failure cannot interrupt typing or saving. Define content-size limits and measure request cost/latency before enabling automatic reviews.

## Decisions for the next conversation

1. Is the first useful result critique/questions, concrete rewrite suggestions, or both? Recommendation: critique first, optional small replacements.
2. Which Langdock deployment and model should be evaluated? Discover accessible models using the existing Settings credential when authorized.
3. Approve the proposed context boundary and independent branch review history.
