// The notes a connected AI tool works with, read from and written to the user's Durable Object.
// Everything is decrypted in memory for one request and dropped afterwards (docs/mcp.md).

import type { Env } from "../env";
import { userSync } from "../sync/stub";
import type { AccountGone, PushChange, RecordQuery, WireRow } from "../sync/types";
import { base64ToBytes, hlcMillis } from "../util";
import {
  CryptoFormatError,
  decodePlaintext,
  derivedId,
  encodePlaintext,
  frame,
  type JsonValue,
  type KeyRing,
  openRecord,
  sealRecord,
  unframe,
} from "./crypto";

export const T = { draft: 1, body: 2, comment: 6, folder: 12 } as const;

/** Bounds per call, so one request can't decrypt an unbounded amount. */
export const NOTE_LIMITS = {
  maxDrafts: 2000,
  searchCiphertextBytes: 25 * 1024 * 1024,
  maxComments: 5000,
  searchResults: 20,
  listDefault: 50,
  listMax: 200,
  snippetChars: 160,
  titleMaxChars: 200,
  textMaxBytes: 1024 * 1024,
  commentMaxChars: 5000,
  quoteMaxChars: 2000,
  editsMax: 50,
} as const;

/** A tool-facing error: the message goes back to the AI tool as is. */
export class ToolError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

const decoder = new TextDecoder("utf-8", { fatal: true });

export interface Draft {
  id: string;
  hlc: string;
  path: string;
  family: string;
  parent: string | null;
  goal: string;
  created: number | null;
  fields: Record<string, JsonValue>;
}

export interface Body {
  id: string;
  hlc: string;
  text: string;
  edited: number | null;
  fields: Record<string, JsonValue>;
}

export interface NoteComment {
  id: string;
  draft: string;
  body: string;
  quote: string;
  author: string | null;
  created: number;
  archived: boolean;
}

export function titleOf(path: string): string {
  const name = path.split("/").pop() ?? path;
  return name.replace(/\.md$/i, "");
}

export function folderOf(path: string): string {
  const parts = path.split("/");
  parts.pop();
  return parts.join("/");
}

function isGone(value: unknown): value is AccountGone {
  return typeof value === "object" && value !== null && (value as AccountGone).gone === true;
}

export class Notes {
  private clock = { ms: 0, counter: 0 };

  constructor(
    private readonly env: Env,
    private readonly ring: KeyRing,
    /** The grant id doubles as the writer's device id in HLCs. */
    private readonly deviceId: string,
  ) {}

  private get store() {
    return userSync(this.env, this.ring.userId);
  }

  private async query(q: RecordQuery): Promise<WireRow[]> {
    const rows: WireRow[] = [];
    let after: string | undefined = q.after;
    for (;;) {
      const page = await this.store.query(this.ring.userId, { ...q, after });
      if (isGone(page)) throw new ToolError("account_deleted", "This Matilde account was deleted.");
      rows.push(...page.rows);
      if (!page.next || rows.length >= q.limit) return rows.slice(0, q.limit);
      after = page.next;
    }
  }

  /** Decrypts a row into its fields; null when it can't be read here (newer key, blob body, newer schema). */
  private async open(row: WireRow): Promise<Record<string, JsonValue> | null> {
    if (row.deleted || !row.ct) return null;
    const ct = base64ToBytes(row.ct);
    if (!ct) return null;
    try {
      const framed = await openRecord(this.ring, { userId: this.ring.userId, recordId: row.id, type: row.type, hlc: row.hlc, deleted: false }, ct, row.keyId);
      const unframed = await unframe(framed);
      if (unframed.kind !== "json") return null;
      return decodePlaintext(unframed.json).fields;
    } catch (error) {
      if (error instanceof CryptoFormatError || error instanceof SyntaxError || error instanceof TypeError) return null;
      throw error;
    }
  }

  private toDraft(row: WireRow, f: Record<string, JsonValue>): Draft | null {
    if (typeof f.path !== "string" || !f.path.toLowerCase().endsWith(".md") || typeof f.family !== "string") return null;
    return {
      id: row.id,
      hlc: row.hlc,
      path: f.path,
      family: f.family,
      parent: typeof f.parent === "string" ? f.parent : null,
      goal: typeof f.goal === "string" ? f.goal : "",
      created: typeof f.created === "number" ? f.created : null,
      fields: f,
    };
  }

  async drafts(): Promise<Draft[]> {
    const rows = await this.query({ types: [T.draft], limit: NOTE_LIMITS.maxDrafts, maxBytes: 4 * 1024 * 1024 });
    const drafts: Draft[] = [];
    for (const row of rows) {
      const f = await this.open(row);
      const draft = f && this.toDraft(row, f);
      if (draft) drafts.push(draft);
    }
    return drafts;
  }

  async draft(id: string): Promise<Draft> {
    const [row] = await this.query({ ids: [id], types: [T.draft], limit: 1, maxBytes: 1 });
    const f = row ? await this.open(row) : null;
    const draft = row && f ? this.toDraft(row, f) : null;
    if (!draft) throw new ToolError("not_found", "No note with this id. Use list_notes or search_notes to find one.");
    return draft;
  }

  /** Body envelopes (no ciphertext) by draft id: for edit times and sizes. */
  async bodyEnvelopes(draftIds: string[]): Promise<Map<string, WireRow>> {
    const ids = await Promise.all(draftIds.map((d) => derivedId("body", d)));
    const byBody = new Map(ids.map((b, i) => [b, draftIds[i]!]));
    const out = new Map<string, WireRow>();
    for (let i = 0; i < ids.length; i += 500) {
      const rows = await this.query({ ids: ids.slice(i, i + 500), types: [T.body], limit: 500, maxBytes: 1, envelopeOnly: true });
      for (const row of rows) out.set(byBody.get(row.id)!, row);
    }
    return out;
  }

  private toBody(row: WireRow, f: Record<string, JsonValue>): Body | null {
    if (typeof f.text !== "string") return null;
    return { id: row.id, hlc: row.hlc, text: f.text, edited: typeof f.edited === "number" ? f.edited : null, fields: f };
  }

  /** The body of a draft; null if it has none yet or it can't be read here (stored as a blob, newer key). */
  async body(draftId: string): Promise<{ body: Body | null; row: WireRow | null }> {
    const id = await derivedId("body", draftId);
    const [row] = await this.query({ ids: [id], types: [T.body], limit: 1, maxBytes: 1 });
    if (!row || row.deleted) return { body: null, row: row ?? null };
    const f = await this.open(row);
    return { body: f ? this.toBody(row, f) : null, row };
  }

  /** Bodies for many drafts, within a ciphertext budget. Returns what fit and whether some were skipped. */
  async bodies(draftIds: string[], budgetBytes: number): Promise<{ bodies: Map<string, Body>; skipped: number }> {
    const envelopes = await this.bodyEnvelopes(draftIds);
    const wanted: string[] = [];
    let budget = budgetBytes;
    let skipped = 0;
    for (const draftId of draftIds) {
      const env = envelopes.get(draftId);
      if (!env || env.deleted) continue;
      if (env.blobId || env.size > budget) {
        skipped += 1;
        continue;
      }
      budget -= env.size;
      wanted.push(env.id);
    }
    const bodies = new Map<string, Body>();
    for (let i = 0; i < wanted.length; i += 200) {
      const rows = await this.query({ ids: wanted.slice(i, i + 200), types: [T.body], limit: 200, maxBytes: 8 * 1024 * 1024 });
      for (const row of rows) {
        const f = await this.open(row);
        const body = f && this.toBody(row, f);
        if (body && typeof f!.draft === "string") bodies.set(f!.draft, body);
        else skipped += 1;
      }
    }
    return { bodies, skipped };
  }

  async comments(draftId: string): Promise<NoteComment[]> {
    const rows = await this.query({ types: [T.comment], limit: NOTE_LIMITS.maxComments, maxBytes: 4 * 1024 * 1024 });
    const out: NoteComment[] = [];
    for (const row of rows) {
      const f = await this.open(row);
      if (!f || f.draft !== draftId || typeof f.body !== "string") continue;
      out.push({
        id: row.id,
        draft: draftId,
        body: f.body,
        quote: typeof f.quote === "string" ? f.quote : "",
        author: typeof f.author === "string" ? f.author : null,
        created: typeof f.created === "number" ? f.created : 0,
        archived: f.archived === true,
      });
    }
    return out.sort((a, b) => a.created - b.created);
  }

  async folders(drafts?: Draft[]): Promise<string[]> {
    const set = new Set<string>();
    const rows = await this.query({ types: [T.folder], limit: NOTE_LIMITS.maxDrafts, maxBytes: 4 * 1024 * 1024 });
    for (const row of rows) {
      const f = await this.open(row);
      if (f && typeof f.path === "string" && f.path) set.add(f.path);
    }
    for (const d of drafts ?? (await this.drafts())) {
      const folder = folderOf(d.path);
      if (folder) set.add(folder);
    }
    return [...set].sort();
  }

  // MARK: writing

  /** A new HLC for this connection, after `after` (another device's clock) and never going backwards. */
  nextHlc(after?: string | null, nowMs = Date.now()): string {
    let ms = Math.max(nowMs, this.clock.ms);
    let counter = ms === this.clock.ms ? this.clock.counter + 1 : 0;
    if (after) {
      const afterMs = hlcMillis(after);
      const afterCounter = Number(after.slice(14, 19));
      if (afterMs > ms || (afterMs === ms && afterCounter >= counter)) {
        ms = afterMs;
        counter = afterCounter + 1;
      }
    }
    if (counter > 99999) {
      ms += 1;
      counter = 0;
    }
    this.clock = { ms, counter };
    return `${String(ms).padStart(13, "0")}.${String(counter).padStart(5, "0")}.${this.deviceId}`;
  }

  async sealChange(id: string, type: number, hlc: string, f: Record<string, JsonValue>, baseHlc: string | null = null): Promise<PushChange> {
    const framed = await frame(encodePlaintext(f, hlc));
    const ct = await sealRecord(this.ring, { userId: this.ring.userId, recordId: id, type, hlc, deleted: false }, framed);
    if (ct.length > 3 * 1024 * 1024) throw new ToolError("too_large", "The note is too large to write from here.");
    return { id, type, hlc, baseHlc, deleted: false, keyId: this.ring.keys[0]!.id, blobId: null, rekey: false, ct };
  }

  async push(changes: PushChange[], nowMs = Date.now()) {
    const result = await this.store.push(this.ring.userId, this.deviceId, changes, nowMs);
    if (isGone(result)) throw new ToolError("account_deleted", "This Matilde account was deleted.");
    return result;
  }
}

export function utf8Length(text: string): number {
  return new TextEncoder().encode(text).length;
}

export function decodeUtf8(bytes: Uint8Array): string {
  return decoder.decode(bytes);
}

/** Folding for search: case- and accent-insensitive. Keeps a map back to the original UTF-16 offsets. */
export function fold(text: string): { folded: string; offsets: number[] } {
  let folded = "";
  const offsets: number[] = [];
  let i = 0;
  for (const ch of text) {
    const base = ch.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
    for (let k = 0; k < base.length; k++) offsets.push(i);
    folded += base;
    i += ch.length;
  }
  offsets.push(i);
  return { folded, offsets };
}

/** All UTF-16 start offsets of `needle` in `text` (literal, overlapping). */
export function occurrences(text: string, needle: string, limit = 2): number[] {
  const out: number[] = [];
  if (!needle) return out;
  let at = text.indexOf(needle);
  while (at !== -1 && out.length < limit) {
    out.push(at);
    at = text.indexOf(needle, at + 1);
  }
  return out;
}

/** Grapheme boundaries via Intl.Segmenter where available, else surrogate pairs only. */
function graphemeStartAt(text: string, index: number): number {
  const Segmenter = (Intl as unknown as { Segmenter?: new (l?: string, o?: { granularity: string }) => { segment(s: string): Iterable<{ index: number; segment: string }> } }).Segmenter;
  if (Segmenter) {
    const from = Math.max(0, index - 64);
    for (const seg of new Segmenter(undefined, { granularity: "grapheme" }).segment(text.slice(from, index + 64))) {
      const start = from + seg.index;
      const end = start + seg.segment.length;
      if (start <= index && index < end) return start;
    }
    return index;
  }
  const code = text.charCodeAt(index);
  return code >= 0xdc00 && code <= 0xdfff && index > 0 ? index - 1 : index;
}

function graphemeEndAt(text: string, index: number): number {
  const start = graphemeStartAt(text, index);
  if (start === index) return index;
  const Segmenter = (Intl as unknown as { Segmenter?: new (l?: string, o?: { granularity: string }) => { segment(s: string): Iterable<{ index: number; segment: string }> } }).Segmenter;
  if (Segmenter) {
    for (const seg of new Segmenter(undefined, { granularity: "grapheme" }).segment(text.slice(start, start + 64))) return start + seg.segment.length;
  }
  return index + 1;
}

/** Quote and context of a UTF-16 range, like MatildeKit's CommentAnchor.context (40 units each side, whole graphemes). */
export function anchorContext(text: string, location: number, length: number): { quote: string; prefix: string; suffix: string } {
  const CONTEXT = 40;
  const end0 = location + length;
  let start = Math.max(0, location - CONTEXT);
  if (start > 0 && start < text.length) {
    const g = graphemeStartAt(text, start);
    if (g < start) start = Math.min(graphemeEndAt(text, start), location);
  }
  let end = Math.min(text.length, end0 + CONTEXT);
  if (end < text.length) {
    const g = graphemeStartAt(text, end);
    if (g < end) end = Math.max(g, end0);
  }
  return { quote: text.slice(location, end0), prefix: text.slice(start, location), suffix: text.slice(end0, end) };
}
