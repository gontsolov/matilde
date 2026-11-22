// Types for connect.js (the consent page's browser module), so the tests can import it.
export interface RingKey {
  id: number;
  key: Uint8Array;
}
export interface ConnectKeys {
  userId: string;
  keyId: number;
  keyCheck: string;
  slots: { slotId: string; kind: string; keyId: number; params: string | null; wrappedKey: string }[];
}
export class KeyError extends Error {
  code: "invalid" | "typo" | "wrong" | "no_slot";
}
export function fields(...values: string[]): Uint8Array;
export function b64(bytes: Uint8Array): string;
export function unb64(text: string): Uint8Array;
export function keyFormat(text: string): "words" | "legacy";
export function wordsEntropy(text: string, words: string[]): Promise<Uint8Array>;
export function slotSecret(text: string, words: string[]): Promise<Uint8Array>;
export function unwrapSlot(secret: Uint8Array, wrapped: Uint8Array, userId: string, slot: { slotId: string; kind: string; keyId: number }): Promise<Uint8Array>;
export function unlockRing(keys: ConnectKeys, text: string, words: string[]): Promise<RingKey[]>;
export function encodeRing(ring: RingKey[]): Uint8Array;
export function wrapForGrant(userId: string, ring: RingKey[], grantId?: string, secret?: Uint8Array): Promise<{ grantId: string; grantSecret: string; wrappedRing: string }>;
