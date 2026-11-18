/** A validated change on its way into a user's Durable Object. */
export interface PushChange {
  id: string;
  type: number;
  hlc: string;
  baseHlc: string | null;
  deleted: boolean;
  keyId: number;
  blobId: string | null;
  /** Re-encryption under a newer key epoch: same HLC, higher keyId (SYNC-06). */
  rekey: boolean;
  /** Ciphertext; null for tombstones. */
  ct: Uint8Array | null;
}

/** A stored record as sent to clients. */
export interface WireRow {
  id: string;
  type: number;
  hlc: string;
  deviceId: string;
  deleted: boolean;
  keyId: number;
  size: number;
  blobId: string | null;
  seq: number;
  /** Base64 ciphertext; null for tombstones. */
  ct: string | null;
}

export type RejectReason = "stale" | "conflict" | "clock" | "blob_missing" | "quota";

export interface PushResult {
  accepted: { id: string; seq: number }[];
  rejected: { id: string; reason: RejectReason; row?: WireRow }[];
  maxSeq: number;
  epoch: string;
}

export interface PullResult {
  rows: WireRow[];
  hasMore: boolean;
  /** Highest seq in the store (not necessarily the last row returned). */
  maxSeq: number;
  /** Pass as `since` for the next page. */
  nextSince: number;
  epoch: string;
  /** True when `since` is ahead of the store: discard the cursor and pull from 0. */
  resync: boolean;
}

export type CommitBlobResult = { ok: true; existed: boolean } | { ok: false; reason: "quota" };

/** Returned instead of a result when the account was deleted (its access token may still be unexpired). */
export interface AccountGone {
  gone: true;
}
