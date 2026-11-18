import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { signAccessToken } from "../src/auth/tokens";
import type { PushResult, PullResult, WireRow } from "../src/sync/types";

export const BASE = "https://sync.test";

export function call(path: string, init: RequestInit = {}): Promise<Response> {
  return (exports as unknown as { default: Fetcher }).default.fetch(new Request(`${BASE}${path}`, init));
}

export interface Device {
  userId: string;
  deviceId: string;
  sessionId: string;
  token: string;
}

/** A device with a valid access token (no D1 session needed: tokens are verified statelessly). */
export async function device(userId: string = crypto.randomUUID()): Promise<Device> {
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const token = await signAccessToken(env, { userId, deviceId, sessionId });
  return { userId, deviceId, sessionId, token };
}

export function authed(dev: { token: string }, init: RequestInit = {}): RequestInit {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${dev.token}`);
  return { ...init, headers };
}

let counter = 0;

/** HLC `<ms:13>.<counter:5>.<deviceId>` */
export function hlc(dev: { deviceId: string }, ms = Date.now()): string {
  counter = (counter + 1) % 100000;
  return `${String(ms).padStart(13, "0")}.${String(counter).padStart(5, "0")}.${dev.deviceId}`;
}

export function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function randomCt(size = 64): string {
  const bytes = new Uint8Array(size);
  for (let i = 0; i < size; i += 65536) crypto.getRandomValues(bytes.subarray(i, Math.min(size, i + 65536)));
  return b64(bytes);
}

export interface ChangeInput {
  id: string;
  type: number;
  hlc: string;
  baseHlc?: string | null;
  deleted?: boolean;
  keyId?: number;
  blobId?: string | null;
  rekey?: boolean;
  ct?: string | null;
}

export function change(input: ChangeInput) {
  return {
    deleted: false,
    keyId: 1,
    ct: input.deleted ? null : randomCt(),
    ...input,
  };
}

export async function push(dev: Device, changes: ReturnType<typeof change>[]): Promise<PushResult> {
  const res = await call(
    "/v1/sync/push",
    authed(dev, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: dev.deviceId, changes }) }),
  );
  if (res.status !== 200) throw new Error(`push failed: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function pull(dev: Device, since = 0, limit?: number): Promise<PullResult> {
  const query = `since=${since}${limit ? `&limit=${limit}` : ""}`;
  const res = await call(`/v1/sync/pull?${query}`, authed(dev));
  if (res.status !== 200) throw new Error(`pull failed: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function pullAll(dev: Device, since = 0): Promise<WireRow[]> {
  const rows: WireRow[] = [];
  let cursor = since;
  for (;;) {
    const page = await pull(dev, cursor);
    rows.push(...page.rows);
    cursor = page.nextSince;
    if (!page.hasMore) return rows;
  }
}

export const T = { draft: 1, body: 2, snapshot: 3, stash: 4, asset: 5, comment: 6 } as const;
