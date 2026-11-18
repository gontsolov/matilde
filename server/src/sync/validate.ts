import { LIMITS, MAX_RECORD_TYPE } from "../limits";
import { base64ToBytes, HLC_RE, HttpError, UUID_RE } from "../util";
import type { PushChange } from "./types";

function fail(message: string): never {
  throw new HttpError(400, "invalid_request", message);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Validates a push body. The server checks shape and sizes only; it never looks inside `ct`. */
export function parsePush(body: unknown, deviceId: string): PushChange[] {
  if (!isObject(body)) fail("body must be an object");
  if (body.deviceId !== undefined && body.deviceId !== deviceId) fail("deviceId does not match the session");
  const changes = body.changes;
  if (!Array.isArray(changes)) fail("changes must be an array");
  if (changes.length === 0) fail("changes is empty");
  if (changes.length > LIMITS.pushMaxChanges) {
    throw new HttpError(413, "batch_too_large", `at most ${LIMITS.pushMaxChanges} changes per push`);
  }
  let total = 0;
  return changes.map((raw, index): PushChange => {
    const at = `changes[${index}]`;
    if (!isObject(raw)) fail(`${at} must be an object`);
    const { id, type, hlc, baseHlc, deleted, keyId, blobId, rekey, ct } = raw;
    if (typeof id !== "string" || !UUID_RE.test(id)) fail(`${at}.id must be a lowercase UUID`);
    if (typeof type !== "number" || !Number.isInteger(type) || type < 1 || type > MAX_RECORD_TYPE) {
      fail(`${at}.type must be an integer 1...${MAX_RECORD_TYPE}`);
    }
    if (typeof hlc !== "string" || !HLC_RE.test(hlc)) fail(`${at}.hlc is malformed`);
    if (baseHlc !== undefined && baseHlc !== null && (typeof baseHlc !== "string" || !HLC_RE.test(baseHlc))) {
      fail(`${at}.baseHlc is malformed`);
    }
    if (typeof deleted !== "boolean") fail(`${at}.deleted must be a boolean`);
    if (typeof keyId !== "number" || !Number.isInteger(keyId) || keyId < 1 || keyId > 0xffff) {
      fail(`${at}.keyId must be a positive integer`);
    }
    if (blobId !== undefined && blobId !== null && (typeof blobId !== "string" || !UUID_RE.test(blobId))) {
      fail(`${at}.blobId must be a lowercase UUID`);
    }
    if (rekey !== undefined && typeof rekey !== "boolean") fail(`${at}.rekey must be a boolean`);
    let bytes: Uint8Array | null = null;
    if (!deleted) {
      if (typeof ct !== "string" || ct.length === 0) fail(`${at}.ct is required unless deleted`);
      bytes = base64ToBytes(ct);
      if (!bytes) fail(`${at}.ct must be base64`);
      if (bytes.byteLength > LIMITS.recordMaxCiphertextBytes) {
        throw new HttpError(413, "record_too_large", `${at}.ct exceeds ${LIMITS.recordMaxCiphertextBytes} bytes`);
      }
      total += bytes.byteLength;
    }
    if (total > LIMITS.pushMaxCiphertextBytes) {
      throw new HttpError(413, "batch_too_large", `at most ${LIMITS.pushMaxCiphertextBytes} ciphertext bytes per push`);
    }
    return {
      id,
      type,
      hlc,
      baseHlc: (baseHlc as string | null | undefined) ?? null,
      deleted,
      keyId,
      blobId: (blobId as string | null | undefined) ?? null,
      rekey: rekey === true,
      ct: bytes,
    };
  });
}
