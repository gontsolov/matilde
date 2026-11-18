/** Server limits. Mirrored in PROTOCOL.md; change both together. */
export const LIMITS = {
  /** Max changes per push. */
  pushMaxChanges: 200,
  /** Max total decoded ciphertext per push. */
  pushMaxCiphertextBytes: 4 * 1024 * 1024,
  /** Max push request body (JSON with base64 ciphertext). */
  pushMaxRequestBytes: 6 * 1024 * 1024,
  /** Max decoded ciphertext of a single record. */
  recordMaxCiphertextBytes: 3 * 1024 * 1024,
  /** Ciphertext above this is stored in R2 instead of the Durable Object row. */
  inlineCiphertextBytes: 256 * 1024,
  /** Pull page size: default and maximum rows. */
  pullDefaultLimit: 500,
  pullMaxLimit: 500,
  /** Pull stops adding rows after this many ciphertext bytes (at least one row is returned). */
  pullMaxBytes: 8 * 1024 * 1024,
  /** Pushes with an HLC this far in the future are rejected. */
  maxClockSkewMs: 5 * 60 * 1000,
  /** Per-user quotas. */
  recordQuotaBytes: 1024 * 1024 * 1024,
  blobQuotaBytes: 5 * 1024 * 1024 * 1024,
  blobMaxBytes: 64 * 1024 * 1024,
  maxDevices: 10,
  maxSocketsPerUser: 20,
  /** Blob garbage collection delays. */
  orphanBlobGraceMs: 7 * 24 * 3600 * 1000,
  unreferencedBlobGraceMs: 30 * 24 * 3600 * 1000,
  supersededObjectGraceMs: 3600 * 1000,
} as const;

/** Record types (cleartext envelope). See PROTOCOL.md. */
export const RecordType = {
  draft: 1,
  body: 2,
  snapshot: 3,
  stash: 4,
  asset: 5,
  comment: 6,
  thread: 7,
  message: 8,
  readMarker: 9,
  trashed: 10,
  settings: 11,
} as const;

/** Types whose writes use compare-and-swap on baseHlc (their conflicts become branches on the client). */
export const CAS_TYPES: ReadonlySet<number> = new Set([RecordType.body, RecordType.stash]);

/** Highest type number accepted, so newer clients can add types without a server change. */
export const MAX_RECORD_TYPE = 63;
