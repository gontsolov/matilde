import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env";
import { CAS_TYPES, LIMITS } from "../limits";
import { bytesToBase64, hlcMillis } from "../util";
import type { CommitBlobResult, PullResult, PushChange, PushResult, RejectReason, WireRow } from "./types";

const SCHEMA_VERSION = 1;

interface RecordRow {
  id: string;
  type: number;
  hlc: string;
  device_id: string;
  deleted: number;
  key_id: number;
  size: number;
  blob_id: string | null;
  ct: ArrayBuffer | null;
  ct_ref: string | null;
  seq: number;
  [key: string]: SqlStorageValue;
}

export class AccountDeletedError extends Error {
  constructor() {
    super("account_deleted");
  }
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

/**
 * One SQLite Durable Object per user: the sync authority. It only ever sees
 * ciphertext plus the cleartext envelope (id, type, HLC, device, deleted,
 * keyId, size, blobId, seq). Every push runs in one synchronous transaction,
 * so sequence numbers and compare-and-swap are race-free.
 */
export class UserSync extends DurableObject<Env> {
  private readonly sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.blockConcurrencyWhile(async () => this.migrate());
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  private migrate(): void {
    this.sql.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value)");
    const version = Number(this.getMeta("schema_version") ?? 0);
    if (version < 1) {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS records (
          id TEXT PRIMARY KEY,
          type INTEGER NOT NULL,
          hlc TEXT NOT NULL,
          device_id TEXT NOT NULL,
          deleted INTEGER NOT NULL,
          key_id INTEGER NOT NULL,
          size INTEGER NOT NULL,
          blob_id TEXT,
          ct BLOB,
          ct_ref TEXT,
          seq INTEGER NOT NULL UNIQUE
        );
        CREATE INDEX IF NOT EXISTS records_blob ON records(blob_id) WHERE blob_id IS NOT NULL;
        CREATE TABLE IF NOT EXISTS blobs (
          id TEXT PRIMARY KEY,
          size INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          delete_after INTEGER
        );
        CREATE TABLE IF NOT EXISTS gc_objects (
          r2_key TEXT PRIMARY KEY,
          delete_after INTEGER NOT NULL
        );
      `);
    }
    // Future migrations: additive only, guarded by `version < N`.
    if (version !== SCHEMA_VERSION) this.setMeta("schema_version", SCHEMA_VERSION);
    if (this.getMeta("epoch") === null) this.setMeta("epoch", crypto.randomUUID());
  }

  // MARK: meta helpers

  private getMeta(key: string): SqlStorageValue {
    const row = this.sql.exec<{ value: SqlStorageValue }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0];
    return row ? row.value : null;
  }

  private setMeta(key: string, value: SqlStorageValue): void {
    this.sql.exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value);
  }

  private num(key: string): number {
    return Number(this.getMeta(key) ?? 0);
  }

  private get epoch(): string {
    return String(this.getMeta("epoch"));
  }

  /** Binds the object to its user on first use and refuses any other user id (defence in depth). */
  private enter(userId: string): void {
    if (this.getMeta("deleted")) throw new AccountDeletedError();
    const owner = this.getMeta("user_id");
    if (owner === null) this.setMeta("user_id", userId);
    else if (owner !== userId) throw new Error("user mismatch");
  }

  private prefix(userId: string): string {
    return `u/${userId}/`;
  }

  // MARK: push

  async push(userId: string, deviceId: string, changes: PushChange[], nowMs = Date.now()): Promise<PushResult> {
    this.enter(userId);

    // Phase 1: large ciphertext goes to R2 under a unique key before the transaction,
    // so the transaction itself stays synchronous.
    const offloaded = new Map<number, string>();
    await Promise.all(
      changes.map(async (change, index) => {
        if (change.ct && change.ct.byteLength > LIMITS.inlineCiphertextBytes) {
          const key = `${this.prefix(userId)}r/${change.id}/${crypto.randomUUID()}`;
          await this.env.BLOBS.put(key, change.ct);
          offloaded.set(index, key);
        }
      }),
    );

    const accepted: PushResult["accepted"] = [];
    const rejected: { id: string; reason: RejectReason; stored?: RecordRow }[] = [];
    const unusedObjects: string[] = [];
    let changed = false;

    // Phase 2: decide and apply every change in one transaction.
    this.ctx.storage.transactionSync(() => {
      let seq = this.num("seq");
      let recordBytes = this.num("record_bytes");

      changes.forEach((change, index) => {
        const ref = offloaded.get(index) ?? null;
        const reject = (reason: RejectReason, stored?: RecordRow) => {
          rejected.push({ id: change.id, reason, stored });
          if (ref) unusedObjects.push(ref);
        };

        if (hlcMillis(change.hlc) > nowMs + LIMITS.maxClockSkewMs) return reject("clock");

        const stored = this.sql.exec<RecordRow>("SELECT * FROM records WHERE id = ?", change.id).toArray()[0];
        const size = change.deleted || !change.ct ? 0 : change.ct.byteLength;

        if (stored && stored.hlc === change.hlc) {
          const isRekey = change.rekey && change.keyId > stored.key_id && !stored.deleted && !change.deleted && change.ct;
          if (!isRekey) {
            // Idempotent retry of a write we already have.
            accepted.push({ id: change.id, seq: stored.seq });
            if (ref) unusedObjects.push(ref);
            return;
          }
        } else {
          if (stored && stored.hlc > change.hlc) return reject("stale", stored);
          if (stored && CAS_TYPES.has(change.type) && change.baseHlc !== stored.hlc) return reject("conflict", stored);
        }

        const blobId = change.deleted ? null : change.blobId;
        if (blobId && !this.sql.exec("SELECT 1 FROM blobs WHERE id = ?", blobId).toArray().length) {
          return reject("blob_missing");
        }
        const nextBytes = recordBytes - (stored?.size ?? 0) + size;
        if (size > 0 && nextBytes > LIMITS.recordQuotaBytes) return reject("quota");

        seq += 1;
        recordBytes = nextBytes;
        const inline = !change.deleted && change.ct && !ref ? toArrayBuffer(change.ct) : null;
        this.sql.exec(
          `INSERT INTO records (id, type, hlc, device_id, deleted, key_id, size, blob_id, ct, ct_ref, seq)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(id) DO UPDATE SET type = excluded.type, hlc = excluded.hlc, device_id = excluded.device_id,
             deleted = excluded.deleted, key_id = excluded.key_id, size = excluded.size, blob_id = excluded.blob_id,
             ct = excluded.ct, ct_ref = excluded.ct_ref, seq = excluded.seq`,
          change.id,
          change.type,
          change.hlc,
          deviceId,
          change.deleted ? 1 : 0,
          change.keyId,
          size,
          blobId,
          inline,
          change.deleted ? null : ref,
          seq,
        );
        if (change.deleted && ref) unusedObjects.push(ref);
        if (stored?.ct_ref) {
          // Pulls in flight may still read the old object; delete it a little later.
          this.sql.exec(
            "INSERT OR REPLACE INTO gc_objects (r2_key, delete_after) VALUES (?, ?)",
            stored.ct_ref,
            nowMs + LIMITS.supersededObjectGraceMs,
          );
        }
        if (blobId) this.sql.exec("UPDATE blobs SET delete_after = NULL WHERE id = ?", blobId);
        if (stored?.blob_id && stored.blob_id !== blobId) {
          // Unreferenced now: delete after the grace period unless something references it again.
          this.sql.exec(
            "UPDATE blobs SET delete_after = ? WHERE id = ? AND NOT EXISTS (SELECT 1 FROM records WHERE blob_id = ? AND deleted = 0)",
            nowMs + LIMITS.unreferencedBlobGraceMs,
            stored.blob_id,
            stored.blob_id,
          );
        }
        accepted.push({ id: change.id, seq });
        changed = true;
      });

      this.setMeta("seq", seq);
      this.setMeta("record_bytes", recordBytes);
    });

    // Phase 3: clean up, build the response, nudge the other devices.
    await Promise.all(unusedObjects.map((key) => this.env.BLOBS.delete(key)));
    await this.scheduleGc();
    const rejectedOut = await Promise.all(
      rejected.map(async ({ id, reason, stored }) =>
        stored ? { id, reason, row: await this.toWire(stored) } : { id, reason },
      ),
    );
    const maxSeq = this.num("seq");
    if (changed) this.nudge(deviceId, maxSeq);
    return { accepted, rejected: rejectedOut, maxSeq, epoch: this.epoch };
  }

  // MARK: pull

  async pull(userId: string, since: number, limit: number): Promise<PullResult> {
    this.enter(userId);
    const maxSeq = this.num("seq");
    if (since > maxSeq) {
      return { rows: [], hasMore: false, maxSeq, nextSince: 0, epoch: this.epoch, resync: true };
    }
    const candidates = this.sql
      .exec<RecordRow>("SELECT * FROM records WHERE seq > ? ORDER BY seq LIMIT ?", since, limit + 1)
      .toArray();
    const page: RecordRow[] = [];
    let bytes = 0;
    for (const row of candidates) {
      if (page.length === limit) break;
      if (page.length > 0 && bytes + row.size > LIMITS.pullMaxBytes) break;
      page.push(row);
      bytes += row.size;
    }
    const rows = await Promise.all(page.map((row) => this.toWire(row)));
    const last = rows[rows.length - 1];
    return {
      rows,
      hasMore: candidates.length > page.length,
      maxSeq,
      nextSince: last ? last.seq : since,
      epoch: this.epoch,
      resync: false,
    };
  }

  private async toWire(row: RecordRow): Promise<WireRow> {
    let ct: string | null = null;
    if (row.ct) {
      ct = bytesToBase64(new Uint8Array(row.ct));
    } else if (row.ct_ref) {
      const object = await this.env.BLOBS.get(row.ct_ref);
      if (!object) throw new Error("missing offloaded ciphertext");
      ct = bytesToBase64(new Uint8Array(await object.arrayBuffer()));
    }
    return {
      id: row.id,
      type: row.type,
      hlc: row.hlc,
      deviceId: row.device_id,
      deleted: row.deleted === 1,
      keyId: row.key_id,
      size: row.size,
      blobId: row.blob_id,
      seq: row.seq,
      ct,
    };
  }

  // MARK: blobs

  async blobInfo(userId: string, blobId: string): Promise<{ exists: boolean; size: number; quotaLeft: number }> {
    this.enter(userId);
    const row = this.sql.exec<{ size: number }>("SELECT size FROM blobs WHERE id = ?", blobId).toArray()[0];
    return { exists: !!row, size: row?.size ?? 0, quotaLeft: LIMITS.blobQuotaBytes - this.num("blob_bytes") };
  }

  /** Registers an uploaded blob. The caller deletes the R2 object when this fails. */
  async commitBlob(userId: string, blobId: string, size: number, nowMs = Date.now()): Promise<CommitBlobResult> {
    this.enter(userId);
    if (this.sql.exec("SELECT 1 FROM blobs WHERE id = ?", blobId).toArray().length) return { ok: true, existed: true };
    const total = this.num("blob_bytes") + size;
    if (total > LIMITS.blobQuotaBytes) return { ok: false, reason: "quota" };
    this.ctx.storage.transactionSync(() => {
      // Uploaded but not yet referenced: collected if no record points at it within the grace period.
      this.sql.exec(
        "INSERT INTO blobs (id, size, created_at, delete_after) VALUES (?, ?, ?, ?)",
        blobId,
        size,
        nowMs,
        nowMs + LIMITS.orphanBlobGraceMs,
      );
      this.setMeta("blob_bytes", total);
    });
    await this.scheduleGc();
    return { ok: true, existed: false };
  }

  // MARK: garbage collection

  private async scheduleGc(): Promise<void> {
    const next = this.sql
      .exec<{ at: number | null }>(
        `SELECT MIN(at) AS at FROM (
           SELECT MIN(delete_after) AS at FROM blobs WHERE delete_after IS NOT NULL
           UNION ALL SELECT MIN(delete_after) FROM gc_objects)`,
      )
      .toArray()[0]?.at;
    if (next === null || next === undefined) return;
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > next) await this.ctx.storage.setAlarm(next);
  }

  override async alarm(): Promise<void> {
    await this.collectGarbage(Date.now());
  }

  /** Deletes expired unreferenced blobs and superseded offloaded ciphertext. */
  async collectGarbage(nowMs: number): Promise<{ blobs: number; objects: number }> {
    const userId = this.getMeta("user_id");
    if (userId === null) return { blobs: 0, objects: 0 };
    const prefix = this.prefix(String(userId));
    let blobs = 0;
    const due = this.sql
      .exec<{ id: string; size: number }>("SELECT id, size FROM blobs WHERE delete_after IS NOT NULL AND delete_after <= ?", nowMs)
      .toArray();
    for (const blob of due) {
      const referenced = this.sql.exec("SELECT 1 FROM records WHERE blob_id = ? AND deleted = 0", blob.id).toArray().length > 0;
      if (referenced) {
        this.sql.exec("UPDATE blobs SET delete_after = NULL WHERE id = ?", blob.id);
        continue;
      }
      await this.env.BLOBS.delete(`${prefix}b/${blob.id}`);
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("DELETE FROM blobs WHERE id = ?", blob.id);
        this.setMeta("blob_bytes", Math.max(0, this.num("blob_bytes") - blob.size));
      });
      blobs += 1;
    }
    const objects = this.sql
      .exec<{ r2_key: string }>("SELECT r2_key FROM gc_objects WHERE delete_after <= ?", nowMs)
      .toArray()
      .map((row) => row.r2_key);
    if (objects.length) {
      await this.env.BLOBS.delete(objects);
      for (const key of objects) this.sql.exec("DELETE FROM gc_objects WHERE r2_key = ?", key);
    }
    await this.scheduleGc();
    return { blobs, objects: objects.length };
  }

  // MARK: sockets

  override async fetch(request: Request): Promise<Response> {
    const userId = request.headers.get("x-matilde-user") ?? "";
    const deviceId = request.headers.get("x-matilde-device") ?? "";
    const sessionId = request.headers.get("x-matilde-session") ?? "";
    try {
      this.enter(userId);
    } catch (error) {
      if (error instanceof AccountDeletedError) return new Response("account deleted", { status: 410 });
      throw error;
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    if (this.ctx.getWebSockets().length >= LIMITS.maxSocketsPerUser) {
      return new Response("too many sockets", { status: 429 });
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [`d:${deviceId}`, `s:${sessionId}`]);
    pair[1].send(JSON.stringify({ type: "hello", seq: this.num("seq"), epoch: this.epoch }));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  override async webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): Promise<void> {
    // Clients only send "ping" (answered by the auto-response without waking us). Ignore anything else.
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try {
      ws.close(code === 1005 ? 1000 : code, "closing");
    } catch {
      // already closed
    }
  }

  private nudge(fromDevice: string, seq: number): void {
    const message = JSON.stringify({ type: "changed", seq });
    for (const ws of this.ctx.getWebSockets()) {
      if (this.ctx.getTags(ws).includes(`d:${fromDevice}`)) continue;
      try {
        ws.send(message);
      } catch {
        // A dead socket is cleaned up by the runtime; the client falls back to polling.
      }
    }
  }

  /** Closes the sockets of a revoked session. */
  async closeSession(sessionId: string): Promise<number> {
    const sockets = this.ctx.getWebSockets(`s:${sessionId}`);
    for (const ws of sockets) {
      try {
        ws.close(4001, "session revoked");
      } catch {
        // ignore
      }
    }
    return sockets.length;
  }

  // MARK: account deletion

  /** Deletes every record, blob and offloaded object of this user, then marks the object as deleted. */
  async deleteAccount(userId: string): Promise<void> {
    const owner = this.getMeta("user_id");
    if (owner !== null && owner !== userId) throw new Error("user mismatch");
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(4002, "account deleted");
      } catch {
        // ignore
      }
    }
    const prefix = this.prefix(userId);
    let cursor: string | undefined;
    do {
      const listing = await this.env.BLOBS.list({ prefix, cursor, limit: 1000 });
      if (listing.objects.length) await this.env.BLOBS.delete(listing.objects.map((o) => o.key));
      cursor = listing.truncated ? listing.cursor : undefined;
    } while (cursor);
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    // Leave a marker so a still-valid access token cannot recreate data.
    this.migrate();
    this.setMeta("user_id", userId);
    this.setMeta("deleted", Date.now());
  }
}
