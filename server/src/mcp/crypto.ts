// Matilde's sync encryption (docs/sync-encryption.md), server side, for the MCP server only.
// Byte-compatible with MatildeKit's SyncCrypto and checked against docs/sync-vectors/v1.json.
// Nothing here logs, stores or returns key material outside the caller's memory.

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export class CryptoFormatError extends Error {}

/** fields(a, b, …): each value as UTF-8 with a UInt16 big-endian byte length prefix. */
export function fields(...values: string[]): Uint8Array {
  const parts = values.map((v) => encoder.encode(v));
  const out = new Uint8Array(parts.reduce((n, p) => n + 2 + p.length, 0));
  let at = 0;
  for (const part of parts) {
    if (part.length > 0xffff) throw new CryptoFormatError("field too long");
    out[at] = part.length >> 8;
    out[at + 1] = part.length & 0xff;
    out.set(part, at + 2);
    at += 2 + part.length;
  }
  return out;
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

function buf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export async function hkdf(ikm: Uint8Array, salt: Uint8Array, info: string, length = 32): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", buf(ikm), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: buf(salt), info: buf(encoder.encode(info)) }, key, length * 8);
  return new Uint8Array(bits);
}

async function aesKey(raw: Uint8Array, usage: "encrypt" | "decrypt"): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", buf(raw), "AES-GCM", false, [usage]);
}

export async function aesSeal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv: buf(nonce), additionalData: buf(aad) }, await aesKey(key, "encrypt"), buf(plaintext));
  return new Uint8Array(ct);
}

export async function aesOpen(key: Uint8Array, nonce: Uint8Array, ct: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
  try {
    const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: buf(nonce), additionalData: buf(aad) }, await aesKey(key, "decrypt"), buf(ct));
    return new Uint8Array(pt);
  } catch {
    throw new CryptoFormatError("authentication failed");
  }
}

export async function hmac(key: Uint8Array, message: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", buf(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, buf(message)));
}

function random(length: number): Uint8Array {
  const out = new Uint8Array(length);
  crypto.getRandomValues(out);
  return out;
}

// MARK: padding (Padmé)

export function paddedLength(length: number): number {
  const n = length + 1;
  if (n <= 32) return 32;
  const e = Math.floor(Math.log2(n));
  const s = Math.floor(Math.log2(e)) + 1;
  const mask = 2 ** (e - s) - 1;
  return (n + mask) & ~mask;
}

export function pad(plaintext: Uint8Array): Uint8Array {
  const out = new Uint8Array(paddedLength(plaintext.length));
  out.set(plaintext);
  out[plaintext.length] = 0x80;
  return out;
}

export function unpad(padded: Uint8Array): Uint8Array {
  let i = padded.length - 1;
  while (i >= 0 && padded[i] === 0) i--;
  if (i < 0 || padded[i] !== 0x80) throw new CryptoFormatError("bad padding");
  return padded.subarray(0, i);
}

// MARK: keys

export interface AccountKey {
  id: number;
  key: Uint8Array;
}

/** The account key ring: current epoch first. */
export interface KeyRing {
  userId: string;
  keys: AccountKey[];
}

export function ringKey(ring: KeyRing, keyId: number): Uint8Array | null {
  return ring.keys.find((k) => k.id === keyId)?.key ?? null;
}

export async function keyCheck(key: Uint8Array, keyId: number): Promise<Uint8Array> {
  return hmac(key, fields("matilde/v1/key-check", String(keyId)));
}

// MARK: record and field envelopes

export interface RecordContext {
  userId: string;
  recordId: string;
  type: number;
  hlc: string;
  deleted: boolean;
}

function recordAad(c: RecordContext, keyId: number): Uint8Array {
  return fields("matilde/v1", c.userId, c.recordId, String(c.type), c.hlc, c.deleted ? "1" : "0", String(keyId));
}

async function sealEnvelope(info: string, ak: AccountKey, plaintext: Uint8Array, aad: Uint8Array, salt = random(32), nonce = random(12)): Promise<Uint8Array> {
  const key = await hkdf(ak.key, salt, info);
  const ct = await aesSeal(key, nonce, pad(plaintext), aad);
  return concat(new Uint8Array([0x01, ak.id >> 8, ak.id & 0xff]), salt, nonce, ct);
}

function envelopeKeyId(envelope: Uint8Array): number {
  if (envelope.length < 3 + 32 + 12 + 16 || envelope[0] !== 0x01) throw new CryptoFormatError("unknown envelope");
  return (envelope[1]! << 8) | envelope[2]!;
}

async function openEnvelope(info: string, envelope: Uint8Array, keyFor: (keyId: number) => Uint8Array | null, aad: (keyId: number) => Uint8Array): Promise<Uint8Array> {
  const keyId = envelopeKeyId(envelope);
  const ak = keyFor(keyId);
  if (!ak) throw new CryptoFormatError("unknown key epoch");
  const salt = envelope.subarray(3, 35);
  const nonce = envelope.subarray(35, 47);
  const key = await hkdf(ak, salt, info);
  return unpad(await aesOpen(key, nonce, envelope.subarray(47), aad(keyId)));
}

export function sealRecord(ring: KeyRing, context: RecordContext, plaintext: Uint8Array, salt?: Uint8Array, nonce?: Uint8Array): Promise<Uint8Array> {
  const current = ring.keys[0];
  if (!current) throw new CryptoFormatError("empty ring");
  return sealEnvelope("matilde/v1/record", current, plaintext, recordAad(context, current.id), salt, nonce);
}

/** Opens a record envelope. `rowKeyId` is the cleartext keyId, which must match the header. */
export function openRecord(ring: KeyRing, context: RecordContext, envelope: Uint8Array, rowKeyId?: number): Promise<Uint8Array> {
  if (rowKeyId !== undefined && envelopeKeyId(envelope) !== rowKeyId) throw new CryptoFormatError("keyId mismatch");
  return openEnvelope("matilde/v1/record", envelope, (id) => ringKey(ring, id), (id) => recordAad(context, id));
}

export function openField(ring: KeyRing, purpose: string, subject: string, envelope: Uint8Array): Promise<Uint8Array> {
  return openEnvelope("matilde/v1/field", envelope, (id) => ringKey(ring, id), (id) => fields("matilde/v1/field", ring.userId, purpose, subject, String(id)));
}

// MARK: key slots (unwrap only; the browser does this at consent, the server in tests)

export async function unwrapSlot(secret: Uint8Array, wrapped: Uint8Array, aad: { userId: string; slotId: string; kind: string; keyId: number }): Promise<Uint8Array> {
  if (wrapped.length < 1 + 32 + 12 + 16 || wrapped[0] !== 0x01) throw new CryptoFormatError("unknown slot");
  const kek = await hkdf(secret, wrapped.subarray(1, 33), `matilde/v1/slot/${aad.kind}`);
  return aesOpen(kek, wrapped.subarray(33, 45), wrapped.subarray(45), fields("matilde/v1/slot", aad.userId, aad.slotId, aad.kind, String(aad.keyId)));
}

export function parseKeyList(bytes: Uint8Array): AccountKey[] {
  if (bytes.length % 34 !== 0) throw new CryptoFormatError("bad key list");
  const keys: AccountKey[] = [];
  for (let at = 0; at < bytes.length; at += 34) keys.push({ id: (bytes[at]! << 8) | bytes[at + 1]!, key: bytes.slice(at + 2, at + 34) });
  return keys;
}

// MARK: grant-wrapped ring (docs/mcp.md, "Grant wrap")

export const GRANT_INFO = "matilde/mcp/v1/grant";

export function encodeRing(keys: AccountKey[]): Uint8Array {
  if (keys.length < 1 || keys.length > 32) throw new CryptoFormatError("bad ring size");
  const out = new Uint8Array(1 + keys.length * 34);
  out[0] = keys.length;
  keys.forEach((k, i) => {
    if (k.key.length !== 32 || k.id < 1 || k.id > 0xffff) throw new CryptoFormatError("bad key");
    out[1 + i * 34] = k.id >> 8;
    out[2 + i * 34] = k.id & 0xff;
    out.set(k.key, 3 + i * 34);
  });
  return out;
}

export function decodeRing(bytes: Uint8Array): AccountKey[] {
  const count = bytes[0] ?? 0;
  if (count < 1 || bytes.length !== 1 + count * 34) throw new CryptoFormatError("bad ring");
  return parseKeyList(bytes.subarray(1));
}

function grantAad(userId: string, grantId: string): Uint8Array {
  return fields(GRANT_INFO, userId, grantId);
}

export async function wrapRing(secret: Uint8Array, userId: string, grantId: string, keys: AccountKey[]): Promise<Uint8Array> {
  const salt = random(32);
  const nonce = random(12);
  const kek = await hkdf(secret, salt, GRANT_INFO);
  return concat(new Uint8Array([0x01]), salt, nonce, await aesSeal(kek, nonce, encodeRing(keys), grantAad(userId, grantId)));
}

export async function unwrapRing(secret: Uint8Array, userId: string, grantId: string, wrapped: Uint8Array): Promise<KeyRing> {
  if (secret.length !== 32) throw new CryptoFormatError("bad grant secret");
  if (wrapped.length < 1 + 32 + 12 + 16 || wrapped[0] !== 0x01) throw new CryptoFormatError("unknown grant wrap");
  const kek = await hkdf(secret, wrapped.subarray(1, 33), GRANT_INFO);
  const plain = await aesOpen(kek, wrapped.subarray(33, 45), wrapped.subarray(45), grantAad(userId, grantId));
  return { userId, keys: decodeRing(plain) };
}

// MARK: framed plaintext (SyncCodec)

export const FRAME = { json: 0x7b, deflate: 0x01, blobReference: 0x02 } as const;
const MAX_INFLATED = 16 * 1024 * 1024;

async function streamBytes(input: Uint8Array, transform: TransformStream<Uint8Array, Uint8Array>, max: number): Promise<Uint8Array> {
  const stream = new Blob([buf(input)]).stream().pipeThrough(transform);
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > max) {
      await reader.cancel();
      throw new CryptoFormatError("inflated too large");
    }
    chunks.push(value);
  }
  return concat(...chunks);
}

export type Unframed = { kind: "json"; json: Uint8Array } | { kind: "blob"; blob: string; size: number };

export async function unframe(framed: Uint8Array): Promise<Unframed> {
  switch (framed[0]) {
    case FRAME.json:
      return { kind: "json", json: framed };
    case FRAME.deflate:
      return { kind: "json", json: await streamBytes(framed.subarray(1), new DecompressionStream("deflate-raw"), MAX_INFLATED) };
    case FRAME.blobReference: {
      const ref = JSON.parse(decoder.decode(framed.subarray(1))) as { blob?: unknown; size?: unknown };
      if (typeof ref.blob !== "string") throw new CryptoFormatError("bad blob reference");
      return { kind: "blob", blob: ref.blob, size: Number(ref.size ?? 0) };
    }
    default:
      throw new CryptoFormatError("unknown frame");
  }
}

/** Frames canonical JSON, compressing it when that saves at least 10 % (like SyncCodec.frame). */
export async function frame(json: Uint8Array): Promise<Uint8Array> {
  if (json.length >= 256) {
    const packed = await streamBytes(json, new CompressionStream("deflate-raw"), json.length * 2 + 64);
    if (packed.length + 1 < json.length - Math.floor(json.length / 10)) return concat(new Uint8Array([FRAME.deflate]), packed);
  }
  return json;
}

// MARK: record plaintext (SyncRecord.plaintext)

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

/** Canonical JSON like MatildeKit's encoder: sorted keys, slashes not escaped. */
export function canonicalJson(value: JsonValue): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k]!)}`).join(",")}}`;
}

export interface RecordPlaintext {
  v: number;
  fields: Record<string, JsonValue>;
  fieldHlcs: Record<string, string>;
}

export function encodePlaintext(fieldsValue: Record<string, JsonValue>, hlc: string): Uint8Array {
  const clean: Record<string, JsonValue> = {};
  for (const [k, v] of Object.entries(fieldsValue)) if (v !== undefined) clean[k] = v;
  const fieldHlcs: Record<string, JsonValue> = {};
  for (const k of Object.keys(clean)) fieldHlcs[k] = hlc;
  return encoder.encode(canonicalJson({ fieldHlcs, fields: clean, v: 1 }));
}

export function decodePlaintext(json: Uint8Array): RecordPlaintext {
  const value = JSON.parse(decoder.decode(json)) as RecordPlaintext;
  if (typeof value !== "object" || value === null || typeof value.v !== "number" || typeof value.fields !== "object") throw new CryptoFormatError("bad plaintext");
  if (value.v > 1) throw new CryptoFormatError("newer schema");
  return value;
}

// MARK: ids

/** UUIDv5 in Matilde's namespace over "<kind>:<key>" (NFC), like SyncID.derived. */
export async function derivedId(kind: string, key: string): Promise<string> {
  const ns = new Uint8Array([0x6d, 0x61, 0x74, 0x6c, 0x64, 0x65, 0x53, 0x79, 0x6e, 0x63, 0x2d, 0x72, 0x65, 0x63, 0x6f, 0x72]);
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-1", buf(concat(ns, encoder.encode(`${kind}:${key}`.normalize("NFC"))))));
  const b = hash.slice(0, 16);
  b[6] = (b[6]! & 0x0f) | 0x50;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
