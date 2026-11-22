// The MCP tools. Each declares the scope it needs; tools/list shows only what a connection may use
// and tools/call checks again. Results are JSON text (plus structuredContent).

import { parseFeedback } from "../feedback/validate";
import { submitFeedback } from "../feedback/service";
import type { Env } from "../env";
import { hlcMillis } from "../util";
import type { JsonValue } from "./crypto";
import type { GrantRow, Scope } from "./grants";
import { anchorContext, folderOf, fold, NOTE_LIMITS, type Notes, occurrences, T, titleOf, ToolError, utf8Length } from "./notes";
import { derivedId } from "./crypto";

export interface ToolContext {
  env: Env;
  grant: GrantRow;
  /** Throws when the connection has no notes access. */
  notes(): Notes;
  ip: string;
  nowMs: number;
}

type Args = Record<string, unknown>;

export interface Tool {
  name: string;
  title: string;
  description: string;
  scope: Scope;
  write: boolean;
  inputSchema: Record<string, unknown>;
  annotations: { readOnlyHint: boolean; destructiveHint: boolean; idempotentHint: boolean; openWorldHint: boolean };
  run(args: Args, ctx: ToolContext): Promise<JsonValue>;
}

function str(args: Args, name: string, opts: { required?: boolean; max?: number; min?: number } = {}): string | undefined {
  const value = args[name];
  if (value === undefined || value === null) {
    if (opts.required) throw new ToolError("invalid_arguments", `${name} is required.`);
    return undefined;
  }
  if (typeof value !== "string") throw new ToolError("invalid_arguments", `${name} must be a string.`);
  if (opts.max !== undefined && value.length > opts.max) throw new ToolError("invalid_arguments", `${name} is too long (at most ${opts.max} characters).`);
  if (opts.min !== undefined && value.trim().length < opts.min) throw new ToolError("invalid_arguments", `${name} must not be empty.`);
  return value;
}

function int(args: Args, name: string, fallback: number, max: number): number {
  const value = args[name];
  if (value === undefined || value === null) return fallback;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1) throw new ToolError("invalid_arguments", `${name} must be a positive integer.`);
  return Math.min(value, max);
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function noteId(args: Args): string {
  const id = str(args, "id", { required: true })!.trim().toLowerCase();
  if (!UUID.test(id)) throw new ToolError("invalid_arguments", "id must be a note id from list_notes or search_notes.");
  return id;
}

function iso(ms: number | null | undefined): string | null {
  return typeof ms === "number" && Number.isFinite(ms) && ms > 0 ? new Date(ms).toISOString() : null;
}

function wordCount(text: string): number {
  return (text.match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) ?? []).length;
}

function snippet(text: string, at: number, length: number): string {
  const half = Math.floor((NOTE_LIMITS.snippetChars - length) / 2);
  const start = Math.max(0, at - Math.max(20, half));
  const end = Math.min(text.length, at + length + Math.max(20, half));
  return `${start > 0 ? "…" : ""}${text.slice(start, end).replace(/\s+/g, " ").trim()}${end < text.length ? "…" : ""}`;
}

const READ = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };

export const TOOLS: Tool[] = [
  {
    name: "list_notes",
    title: "List notes",
    description:
      "List the user's Matilde notes, most recently edited first: id, title, folder, created and edited times. Alternate drafts of a note have `alternateOf` set. Use the id with read_note.",
    scope: "notes:read",
    write: false,
    inputSchema: {
      type: "object",
      properties: {
        folder: { type: "string", description: "Only notes in this folder (as shown in `folder`). Empty string = top level." },
        limit: { type: "integer", minimum: 1, maximum: NOTE_LIMITS.listMax, description: `Default ${NOTE_LIMITS.listDefault}.` },
        cursor: { type: "string", description: "`nextCursor` from the previous call." },
      },
      additionalProperties: false,
    },
    annotations: READ,
    async run(args, ctx) {
      const folder = str(args, "folder", { max: 500 });
      const limit = int(args, "limit", NOTE_LIMITS.listDefault, NOTE_LIMITS.listMax);
      const offset = Number(str(args, "cursor") ?? 0);
      if (!Number.isInteger(offset) || offset < 0) throw new ToolError("invalid_arguments", "cursor is malformed.");
      const notes = ctx.notes();
      let drafts = await notes.drafts();
      if (folder !== undefined) drafts = drafts.filter((d) => folderOf(d.path) === folder.replace(/^\/+|\/+$/g, ""));
      const bodies = await notes.bodyEnvelopes(drafts.map((d) => d.id));
      const rows = drafts
        .map((d) => {
          const body = bodies.get(d.id);
          return {
            id: d.id,
            title: titleOf(d.path),
            folder: folderOf(d.path),
            ...(d.parent ? { alternateOf: d.parent } : {}),
            created: iso(d.created),
            edited: iso(body ? hlcMillis(body.hlc) : hlcMillis(d.hlc)),
            sortKey: body ? hlcMillis(body.hlc) : hlcMillis(d.hlc),
          };
        })
        .sort((a, b) => b.sortKey - a.sortKey);
      const page = rows.slice(offset, offset + limit).map(({ sortKey: _sortKey, ...rest }) => rest);
      const next = offset + limit < rows.length ? String(offset + limit) : null;
      return { notes: page, total: rows.length, nextCursor: next };
    },
  },
  {
    name: "search_notes",
    title: "Search notes",
    description:
      "Search the user's Matilde notes for text (case- and accent-insensitive, in titles and bodies). Returns up to 20 notes with a snippet around the first match.",
    scope: "notes:read",
    write: false,
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", minLength: 1, maxLength: 200 },
        limit: { type: "integer", minimum: 1, maximum: NOTE_LIMITS.searchResults },
      },
      required: ["query"],
      additionalProperties: false,
    },
    annotations: READ,
    async run(args, ctx) {
      const query = str(args, "query", { required: true, max: 200, min: 1 })!.trim();
      const limit = int(args, "limit", NOTE_LIMITS.searchResults, NOTE_LIMITS.searchResults);
      const needle = fold(query).folded;
      const notes = ctx.notes();
      const drafts = await notes.drafts();
      const { bodies, skipped } = await notes.bodies(
        drafts.map((d) => d.id),
        NOTE_LIMITS.searchCiphertextBytes,
      );
      const results: JsonValue[] = [];
      let matches = 0;
      for (const d of drafts) {
        const title = titleOf(d.path);
        const body = bodies.get(d.id);
        const inTitle = fold(title).folded.includes(needle);
        let snip: string | null = null;
        if (body) {
          const f = fold(body.text);
          const at = f.folded.indexOf(needle);
          if (at !== -1) {
            const start = f.offsets[at]!;
            const end = f.offsets[at + needle.length] ?? body.text.length;
            snip = snippet(body.text, start, end - start);
          }
        }
        if (!inTitle && snip === null) continue;
        matches += 1;
        if (results.length < limit) {
          results.push({ id: d.id, title, folder: folderOf(d.path), ...(d.parent ? { alternateOf: d.parent } : {}), snippet: snip ?? "" });
        }
      }
      return { results, matches, ...(skipped ? { notSearched: skipped, note: "Some very large notes were not searched." } : {}) };
    },
  },
  {
    name: "read_note",
    title: "Read a note",
    description: "Read one Matilde note: title, folder, goal, the Markdown text and the user's private comments on it.",
    scope: "notes:read",
    write: false,
    inputSchema: { type: "object", properties: { id: { type: "string", description: "Note id." } }, required: ["id"], additionalProperties: false },
    annotations: READ,
    async run(args, ctx) {
      const id = noteId(args);
      const notes = ctx.notes();
      const draft = await notes.draft(id);
      const { body, row } = await notes.body(id);
      if (row && !body && !row.deleted) throw new ToolError("unreadable", "This note can't be read from here (it is very large or was written by a newer Matilde).");
      const comments = (await notes.comments(id)).filter((c) => !c.archived);
      return {
        id,
        title: titleOf(draft.path),
        folder: folderOf(draft.path),
        goal: draft.goal,
        ...(draft.parent ? { alternateOf: draft.parent } : {}),
        created: iso(draft.created),
        edited: iso(body ? hlcMillis(body.hlc) : null),
        words: body ? wordCount(body.text) : 0,
        text: body?.text ?? "",
        comments: comments.map((c) => ({ quote: c.quote, comment: c.body, ...(c.author ? { author: c.author } : {}), created: iso(c.created) })),
      };
    },
  },
  {
    name: "create_note",
    title: "Create a note",
    description:
      "Create a new Matilde note with a title and Markdown text. It appears in the user's Matilde apps on their next sync. The title becomes the file name; if it is taken, a number is added.",
    scope: "notes:create",
    write: true,
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", minLength: 1, maxLength: NOTE_LIMITS.titleMaxChars },
        text: { type: "string", description: "Markdown body." },
        folder: { type: "string", description: "An existing folder (as returned by list_notes). Default: top level." },
      },
      required: ["title", "text"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    async run(args, ctx) {
      const rawTitle = str(args, "title", { required: true, max: NOTE_LIMITS.titleMaxChars, min: 1 })!;
      const title = rawTitle.replace(/[\/:\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().replace(/^\.+/, "").replace(/\.md$/i, "").trim();
      if (!title) throw new ToolError("invalid_arguments", "title must contain letters or digits.");
      const text = str(args, "text", { required: true })!;
      if (utf8Length(text) > NOTE_LIMITS.textMaxBytes) throw new ToolError("too_large", "text is too long (at most 1 MB).");
      const notes = ctx.notes();
      const drafts = await notes.drafts();
      let folder = (str(args, "folder", { max: 500 }) ?? "").replace(/^\/+|\/+$/g, "");
      if (folder) {
        const folders = await notes.folders(drafts);
        const match = folders.find((f) => f === folder) ?? folders.find((f) => f.toLowerCase() === folder.toLowerCase());
        if (!match) throw new ToolError("unknown_folder", `There is no folder "${folder}". Existing folders: ${folders.slice(0, 50).join(", ") || "none"}.`);
        folder = match;
      }
      const taken = new Set(drafts.map((d) => d.path.toLowerCase()));
      const pathFor = (name: string) => (folder ? `${folder}/${name}.md` : `${name}.md`);
      let path = pathFor(title);
      for (let n = 2; taken.has(path.toLowerCase()); n++) path = pathFor(`${title} ${n}`);
      const id = crypto.randomUUID();
      const draftHlc = notes.nextHlc(null, ctx.nowMs);
      const bodyHlc = notes.nextHlc(draftHlc, ctx.nowMs);
      const bodyId = await derivedId("body", id);
      const changes = [
        await notes.sealChange(id, T.draft, draftHlc, { path, family: id, goal: "", created: ctx.nowMs }),
        await notes.sealChange(bodyId, T.body, bodyHlc, { draft: id, text, edited: ctx.nowMs }, null),
      ];
      const result = await notes.push(changes, ctx.nowMs);
      if (result.rejected.length) throw new ToolError("write_failed", "The note could not be saved. Try again.");
      return { id, title: titleOf(path), folder };
    },
  },
  {
    name: "add_comment",
    title: "Comment on a note",
    description:
      "Add a private comment to a passage of a Matilde note, shown in the margin in the user's apps with your name. `quote` must be copied exactly from the note's text and occur only once in it (include a few more words if needed).",
    scope: "notes:comment",
    write: true,
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Note id." },
        quote: { type: "string", minLength: 1, maxLength: NOTE_LIMITS.quoteMaxChars, description: "The exact passage the comment is about." },
        comment: { type: "string", minLength: 1, maxLength: NOTE_LIMITS.commentMaxChars },
      },
      required: ["id", "quote", "comment"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    async run(args, ctx) {
      const id = noteId(args);
      const quote = str(args, "quote", { required: true, max: NOTE_LIMITS.quoteMaxChars, min: 1 })!;
      const comment = str(args, "comment", { required: true, max: NOTE_LIMITS.commentMaxChars, min: 1 })!.trim();
      const notes = ctx.notes();
      await notes.draft(id);
      const { body } = await notes.body(id);
      if (!body) throw new ToolError("unreadable", "This note has no text that can be commented on from here.");
      const found = occurrences(body.text, quote, 2);
      if (found.length === 0) throw new ToolError("quote_not_found", "quote does not occur in the note. Copy it exactly from read_note.");
      if (found.length > 1) throw new ToolError("quote_ambiguous", "quote occurs more than once. Include a few more words so it is unique.");
      const location = found[0]!;
      const anchor = anchorContext(body.text, location, quote.length);
      const commentId = crypto.randomUUID();
      const hlc = notes.nextHlc(null, ctx.nowMs);
      const change = await notes.sealChange(commentId, T.comment, hlc, {
        draft: id,
        body: comment,
        location,
        length: quote.length,
        quote: anchor.quote,
        prefix: anchor.prefix,
        suffix: anchor.suffix,
        created: ctx.nowMs,
        modified: ctx.nowMs,
        archived: false,
        author: ctx.grant.client_name.slice(0, 80),
      });
      const result = await notes.push([change], ctx.nowMs);
      if (result.rejected.length) throw new ToolError("write_failed", "The comment could not be saved. Try again.");
      return { ok: true, commentId };
    },
  },
  {
    name: "edit_note",
    title: "Edit a note",
    description:
      "Change the text of a Matilde note with exact replacements. Each `old_text` must be copied exactly from the current text (read_note) and occur only once; it is replaced by `new_text`. Fails without changing anything if the note was edited in the meantime: read it again and retry.",
    scope: "notes:edit",
    write: true,
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Note id." },
        edits: {
          type: "array",
          minItems: 1,
          maxItems: NOTE_LIMITS.editsMax,
          items: {
            type: "object",
            properties: { old_text: { type: "string", minLength: 1 }, new_text: { type: "string" } },
            required: ["old_text", "new_text"],
            additionalProperties: false,
          },
        },
      },
      required: ["id", "edits"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    async run(args, ctx) {
      const id = noteId(args);
      const edits = args.edits;
      if (!Array.isArray(edits) || edits.length === 0 || edits.length > NOTE_LIMITS.editsMax) {
        throw new ToolError("invalid_arguments", `edits must have 1 to ${NOTE_LIMITS.editsMax} entries.`);
      }
      const notes = ctx.notes();
      await notes.draft(id);
      const { body, row } = await notes.body(id);
      if (!body || !row) throw new ToolError("unreadable", "This note's text can't be edited from here.");
      let text = body.text;
      edits.forEach((raw, index) => {
        const e = raw as Record<string, unknown>;
        if (typeof e?.old_text !== "string" || !e.old_text || typeof e.new_text !== "string") {
          throw new ToolError("invalid_arguments", `edits[${index}] needs old_text (non-empty) and new_text.`);
        }
        const found = occurrences(text, e.old_text, 2);
        if (found.length === 0) throw new ToolError("old_text_not_found", `edits[${index}].old_text does not occur in the note. Nothing was changed.`);
        if (found.length > 1) throw new ToolError("old_text_ambiguous", `edits[${index}].old_text occurs more than once. Include more context. Nothing was changed.`);
        text = text.slice(0, found[0]!) + e.new_text + text.slice(found[0]! + e.old_text.length);
      });
      if (utf8Length(text) > NOTE_LIMITS.textMaxBytes) throw new ToolError("too_large", "The edited text is too long (at most 1 MB).");
      if (text === body.text) return { ok: true, changed: false };
      const hlc = notes.nextHlc(row.hlc, ctx.nowMs);
      const change = await notes.sealChange(row.id, T.body, hlc, { ...body.fields, text, edited: ctx.nowMs }, row.hlc);
      const result = await notes.push([change], ctx.nowMs);
      const rejected = result.rejected[0];
      if (rejected) {
        throw new ToolError("note_changed", "The note changed while you were editing it. Nothing was changed: read it again and retry.");
      }
      return { ok: true, changed: true };
    },
  },
  {
    name: "leave_feedback",
    title: "Send feedback about Matilde",
    description:
      "Send feedback about the Matilde app (a bug, an idea or something else) on the user's behalf, after they asked for it. Don't include note content unless the user explicitly wants it included.",
    scope: "feedback",
    write: true,
    inputSchema: {
      type: "object",
      properties: {
        message: { type: "string", minLength: 1, maxLength: 4000 },
        kind: { type: "string", enum: ["bug", "idea", "other"] },
        replyEmail: { type: "string", description: "Only if the user wants an answer and gave this address." },
      },
      required: ["message"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    async run(args, ctx) {
      const message = str(args, "message", { required: true, max: 4000, min: 1 })!;
      const client = ctx.grant.client_name.replace(/[\u0000-\u001f]/g, " ").slice(0, 80);
      let input;
      try {
        input = parseFeedback({ message: `${message}\n\n(Sent from ${client} via MCP)`, kind: args.kind ?? "other", replyEmail: args.replyEmail });
      } catch (error) {
        throw new ToolError("invalid_arguments", error instanceof Error ? error.message : "invalid feedback");
      }
      const result = await submitFeedback(ctx.env, input, { ip: ctx.ip, signedIn: ctx.grant.wrapped_ring !== null }, ctx.nowMs);
      return { ok: true, status: result.status === "sent" ? "sent" : "saved, will be delivered shortly" };
    },
  },
];

export function toolsFor(scopes: readonly string[]): Tool[] {
  return TOOLS.filter((t) => scopes.includes(t.scope));
}
