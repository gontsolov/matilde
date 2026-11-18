import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { SignJWT, importJWK } from "jose";
import { LIMITS } from "../src/limits";
import { userSync } from "../src/sync/stub";
import type { UserSync } from "../src/sync/UserSync";
import { authed, b64, call, change, device, hlc, pull, pullAll, push, randomCt, T } from "./helpers";

describe("access", () => {
  it("rejects requests without a valid access token", async () => {
    expect((await call("/v1/sync/pull")).status).toBe(401);
    expect((await call("/v1/sync/pull", { headers: { Authorization: "Bearer nope" } })).status).toBe(401);
  });

  it("rejects tokens signed by an unknown key", async () => {
    const jwk = JSON.parse(env.OTHER_SIGNING_KEY);
    const key = await importJWK(jwk, "EdDSA");
    const forged = await new SignJWT({ sid: crypto.randomUUID(), did: crypto.randomUUID() })
      .setProtectedHeader({ alg: "EdDSA", kid: "test-1", typ: "at+jwt" })
      .setIssuer("matilde-sync")
      .setAudience("matilde-app")
      .setSubject(crypto.randomUUID())
      .setIssuedAt()
      .setExpirationTime("15m")
      .sign(key);
    expect((await call("/v1/sync/pull", { headers: { Authorization: `Bearer ${forged}` } })).status).toBe(401);
  });

  it("rejects expired tokens", async () => {
    const { signAccessToken } = await import("../src/auth/tokens");
    const token = await signAccessToken(
      env,
      { userId: crypto.randomUUID(), deviceId: crypto.randomUUID(), sessionId: crypto.randomUUID() },
      Date.now() - 16 * 60 * 1000,
    );
    expect((await call("/v1/sync/pull", { headers: { Authorization: `Bearer ${token}` } })).status).toBe(401);
  });

  it("answers health without auth", async () => {
    expect(await (await call("/v1/health")).json()).toEqual({ ok: true, api: "v1" });
  });
});

describe("push and pull", () => {
  it("assigns increasing sequence numbers and pulls by cursor", async () => {
    const dev = await device();
    const ids = Array.from({ length: 5 }, () => crypto.randomUUID());
    const result = await push(dev, ids.map((id) => change({ id, type: T.draft, hlc: hlc(dev) })));
    expect(result.rejected).toEqual([]);
    expect(result.accepted.map((a) => a.seq)).toEqual([1, 2, 3, 4, 5]);
    expect(result.maxSeq).toBe(5);

    const first = await pull(dev, 0, 2);
    expect(first.rows.map((r) => r.id)).toEqual(ids.slice(0, 2));
    expect(first.hasMore).toBe(true);
    expect(first.nextSince).toBe(2);
    const rest = await pull(dev, first.nextSince);
    expect(rest.rows.map((r) => r.id)).toEqual(ids.slice(2));
    expect(rest.hasMore).toBe(false);
    expect(rest.epoch).toBe(first.epoch);

    const empty = await pull(dev, 5);
    expect(empty.rows).toEqual([]);
    expect(empty.nextSince).toBe(5);
  });

  it("returns the envelope and exact ciphertext", async () => {
    const dev = await device();
    const id = crypto.randomUUID();
    const ct = randomCt(100);
    const h = hlc(dev);
    await push(dev, [change({ id, type: T.comment, hlc: h, keyId: 3, ct })]);
    const [row] = (await pull(dev)).rows;
    expect(row).toEqual({ id, type: T.comment, hlc: h, deviceId: dev.deviceId, deleted: false, keyId: 3, size: 100, blobId: null, seq: 1, ct });
  });

  it("treats a retried write as an accepted no-op", async () => {
    const dev = await device();
    const c = change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev) });
    const first = await push(dev, [c]);
    const again = await push(dev, [c]);
    expect(again.accepted).toEqual(first.accepted);
    expect(again.maxSeq).toBe(1);
  });

  it("is last-writer-wins by HLC for metadata and returns the stored row on rejection", async () => {
    const a = await device();
    const b = await device(a.userId);
    const id = crypto.randomUUID();
    const t0 = Date.now() - 10_000;
    const newer = change({ id, type: T.draft, hlc: hlc(b, t0 + 5000) });
    const older = change({ id, type: T.draft, hlc: hlc(a, t0) });
    await push(b, [newer]);
    const result = await push(a, [older]);
    expect(result.accepted).toEqual([]);
    expect(result.rejected).toHaveLength(1);
    expect(result.rejected[0]!.reason).toBe("stale");
    expect(result.rejected[0]!.row!.hlc).toBe(newer.hlc);
    expect(result.rejected[0]!.row!.ct).toBe(newer.ct);

    // Metadata ignores baseHlc: a newer write wins even with a stale base.
    const merged = change({ id, type: T.draft, hlc: hlc(a, t0 + 9000), baseHlc: older.hlc });
    expect((await push(a, [merged])).accepted).toHaveLength(1);
  });

  it("rejects HLCs too far in the future", async () => {
    const dev = await device();
    const result = await push(dev, [change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev, Date.now() + LIMITS.maxClockSkewMs + 60_000) })]);
    expect(result.rejected).toEqual([{ id: expect.any(String), reason: "clock" }]);
    expect(result.maxSeq).toBe(0);
  });

  it("keeps tombstones as envelopes without ciphertext", async () => {
    const dev = await device();
    const id = crypto.randomUUID();
    await push(dev, [change({ id, type: T.comment, hlc: hlc(dev) })]);
    await push(dev, [change({ id, type: T.comment, hlc: hlc(dev), deleted: true })]);
    const rows = await pullAll(dev);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ id, deleted: true, ct: null, size: 0, seq: 2 });
  });

  it("accepts a rekey write with the same HLC and a newer key", async () => {
    const dev = await device();
    const id = crypto.randomUUID();
    const h = hlc(dev);
    await push(dev, [change({ id, type: T.body, hlc: h, keyId: 1 })]);
    const rekeyed = change({ id, type: T.body, hlc: h, keyId: 2, rekey: true });
    const result = await push(dev, [rekeyed]);
    expect(result.accepted).toEqual([{ id, seq: 2 }]);
    const [row] = await pullAll(dev);
    expect(row).toMatchObject({ keyId: 2, ct: rekeyed.ct, hlc: h });
  });

  it("signals a resync when the cursor is ahead of the store", async () => {
    const dev = await device();
    const result = await pull(dev, 42);
    expect(result.resync).toBe(true);
    expect(result.nextSince).toBe(0);
  });

  it("validates input", async () => {
    const dev = await device();
    const send = (changes: unknown) =>
      call("/v1/sync/push", authed(dev, { method: "POST", body: JSON.stringify({ changes }) }));
    expect((await send([change({ id: crypto.randomUUID().toUpperCase(), type: T.draft, hlc: hlc(dev) })])).status).toBe(400);
    expect((await send([change({ id: crypto.randomUUID(), type: T.draft, hlc: "yesterday" })])).status).toBe(400);
    expect((await send([change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev), ct: "not base64!" })])).status).toBe(400);
    expect((await send([{ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev), deleted: false, keyId: 1 }])).status).toBe(400);
    const many = Array.from({ length: LIMITS.pushMaxChanges + 1 }, () => change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev) }));
    expect((await send(many)).status).toBe(413);
    const wrongDevice = await call(
      "/v1/sync/push",
      authed(dev, { method: "POST", body: JSON.stringify({ deviceId: crypto.randomUUID(), changes: [change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev) })] }) }),
    );
    expect(wrongDevice.status).toBe(400);
  });
});

describe("conflict detection for bodies", () => {
  it("accepts a body write whose baseHlc matches and flags a conflict otherwise", async () => {
    const mac = await device();
    const air = await device(mac.userId);
    const id = crypto.randomUUID();
    const v1 = change({ id, type: T.body, hlc: hlc(mac), baseHlc: null });
    expect((await push(mac, [v1])).accepted).toHaveLength(1);

    // Air pulled v1 and edits it.
    const v2 = change({ id, type: T.body, hlc: hlc(air), baseHlc: v1.hlc });
    expect((await push(air, [v2])).accepted).toHaveLength(1);

    // Mac edits v1 offline with a newer clock: still a conflict, because its base is v1, not v2.
    const v2b = change({ id, type: T.body, hlc: hlc(mac, Date.now() + 1000), baseHlc: v1.hlc });
    const result = await push(mac, [v2b]);
    expect(result.accepted).toEqual([]);
    expect(result.rejected[0]).toMatchObject({ id, reason: "conflict", row: { hlc: v2.hlc, ct: v2.ct, deviceId: air.deviceId } });

    // The client branches its text and pushes the server version unchanged; a write on the right base succeeds.
    const v3 = change({ id, type: T.body, hlc: hlc(mac, Date.now() + 2000), baseHlc: v2.hlc });
    expect((await push(mac, [v3])).accepted).toHaveLength(1);
  });

  it("treats creating a body that already exists as a conflict", async () => {
    const a = await device();
    const b = await device(a.userId);
    const id = crypto.randomUUID();
    await push(a, [change({ id, type: T.stash, hlc: hlc(a) })]);
    const result = await push(b, [change({ id, type: T.stash, hlc: hlc(b, Date.now() + 1000) })]);
    expect(result.rejected[0]!.reason).toBe("conflict");
  });

  it("turns an edit of a tombstoned body into a conflict", async () => {
    const a = await device();
    const b = await device(a.userId);
    const id = crypto.randomUUID();
    const v1 = change({ id, type: T.body, hlc: hlc(a) });
    await push(a, [v1]);
    const gone = change({ id, type: T.body, hlc: hlc(a), baseHlc: v1.hlc, deleted: true });
    expect((await push(a, [gone])).accepted).toHaveLength(1);
    const edit = change({ id, type: T.body, hlc: hlc(b, Date.now() + 1000), baseHlc: v1.hlc });
    const result = await push(b, [edit]);
    expect(result.rejected[0]).toMatchObject({ reason: "conflict", row: { deleted: true, ct: null } });
  });
});

describe("large records and blobs", () => {
  it("stores ciphertext over 256 KB in R2 and returns it unchanged", async () => {
    const dev = await device();
    const id = crypto.randomUUID();
    const big = randomCt(300 * 1024);
    await push(dev, [change({ id, type: T.body, hlc: hlc(dev), ct: big })]);
    const objects = await env.BLOBS.list({ prefix: `u/${dev.userId}/r/${id}/` });
    expect(objects.objects).toHaveLength(1);
    const [row] = await pullAll(dev);
    expect(row!.ct).toBe(big);
    expect(row!.size).toBe(300 * 1024);

    // Replacing it schedules the old object for deletion after the grace period.
    const [v1] = await pullAll(dev);
    await push(dev, [change({ id, type: T.body, hlc: hlc(dev), baseHlc: v1!.hlc })]);
    const stub = userSync(env, dev.userId);
    await runInDurableObject(stub, (instance: UserSync) => instance.collectGarbage(Date.now() + LIMITS.supersededObjectGraceMs + 1));
    expect((await env.BLOBS.list({ prefix: `u/${dev.userId}/r/` })).objects).toHaveLength(0);
  });

  it("uploads, references, downloads and garbage-collects blobs", async () => {
    const dev = await device();
    const blobId = crypto.randomUUID();
    const bytes = new Uint8Array(1000);
    crypto.getRandomValues(bytes);

    const assetId = crypto.randomUUID();
    const early = await push(dev, [change({ id: assetId, type: T.asset, hlc: hlc(dev), blobId })]);
    expect(early.rejected[0]!.reason).toBe("blob_missing");

    const put = await call(`/v1/blobs/${blobId}`, authed(dev, { method: "PUT", body: bytes, headers: { "Content-Length": "1000" } }));
    expect(put.status).toBe(201);
    const again = await call(`/v1/blobs/${blobId}`, authed(dev, { method: "PUT", body: bytes, headers: { "Content-Length": "1000" } }));
    expect(again.status).toBe(200);
    expect(await again.json()).toMatchObject({ existed: true });

    const v1 = change({ id: assetId, type: T.asset, hlc: hlc(dev), blobId });
    expect((await push(dev, [v1])).accepted).toHaveLength(1);

    const got = await call(`/v1/blobs/${blobId}`, authed(dev));
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(bytes);

    const stub = userSync(env, dev.userId);
    // Referenced blobs survive GC.
    await runInDurableObject(stub, (i: UserSync) => i.collectGarbage(Date.now() + LIMITS.unreferencedBlobGraceMs * 2));
    expect((await call(`/v1/blobs/${blobId}`, authed(dev))).status).toBe(200);

    // Tombstoning the asset releases the blob after 30 days.
    await push(dev, [change({ id: assetId, type: T.asset, hlc: hlc(dev), deleted: true })]);
    await runInDurableObject(stub, (i: UserSync) => i.collectGarbage(Date.now() + 1000));
    expect((await call(`/v1/blobs/${blobId}`, authed(dev))).status).toBe(200);
    const collected = await runInDurableObject(stub, (i: UserSync) => i.collectGarbage(Date.now() + LIMITS.unreferencedBlobGraceMs + 1000));
    expect(collected.blobs).toBe(1);
    expect((await call(`/v1/blobs/${blobId}`, authed(dev))).status).toBe(404);
  });

  it("collects uploaded blobs nobody references", async () => {
    const dev = await device();
    const blobId = crypto.randomUUID();
    await call(`/v1/blobs/${blobId}`, authed(dev, { method: "PUT", body: new Uint8Array(10), headers: { "Content-Length": "10" } }));
    const stub = userSync(env, dev.userId);
    const result = await runInDurableObject(stub, (i: UserSync) => i.collectGarbage(Date.now() + LIMITS.orphanBlobGraceMs + 1000));
    expect(result.blobs).toBe(1);
  });

  it("requires a length and refuses oversized blobs", async () => {
    const dev = await device();
    const res = await call(
      `/v1/blobs/${crypto.randomUUID()}`,
      authed(dev, { method: "PUT", body: "x", headers: { "Content-Length": String(LIMITS.blobMaxBytes + 1) } }),
    );
    expect(res.status).toBe(413);
  });
});

describe("per-user isolation", () => {
  it("never shows one user's records or blobs to another", async () => {
    const anna = await device();
    const ben = await device();
    const id = crypto.randomUUID();
    await push(anna, [change({ id, type: T.draft, hlc: hlc(anna) })]);
    const blobId = crypto.randomUUID();
    await call(`/v1/blobs/${blobId}`, authed(anna, { method: "PUT", body: new Uint8Array(5), headers: { "Content-Length": "5" } }));

    expect((await pull(ben)).rows).toEqual([]);
    expect((await call(`/v1/blobs/${blobId}`, authed(ben))).status).toBe(404);

    // Ben writing the same record id lands in his own store and doesn't touch Anna's.
    await push(ben, [change({ id, type: T.draft, hlc: hlc(ben, Date.now() + 1000) })]);
    const annaRows = await pullAll(anna);
    expect(annaRows).toHaveLength(1);
    expect(annaRows[0]!.deviceId).toBe(anna.deviceId);
  });

  it("binds each Durable Object to one user id", async () => {
    const anna = await device();
    await push(anna, [change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(anna) })]);
    const stub = userSync(env, anna.userId);
    await runInDurableObject(stub, async (instance: UserSync) => {
      await expect(instance.pull(crypto.randomUUID(), 0, 10)).rejects.toThrow("user mismatch");
    });
  });
});

describe("change nudges", () => {
  it("tells the user's other devices about new changes, not the writer", async () => {
    const mac = await device();
    const air = await device(mac.userId);
    const open = async (dev: typeof mac) => {
      const res = await call("/v1/sync/ws", authed(dev, { headers: { Upgrade: "websocket" } }));
      expect(res.status).toBe(101);
      const ws = res.webSocket!;
      const messages: unknown[] = [];
      ws.addEventListener("message", (event) => messages.push(JSON.parse(event.data as string)));
      ws.accept();
      return { ws, messages };
    };
    const airSocket = await open(air);
    const macSocket = await open(mac);
    await push(mac, [change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(mac) })]);
    await expect.poll(() => airSocket.messages.length).toBe(2);
    expect(airSocket.messages).toEqual([
      { type: "hello", seq: 0, epoch: expect.any(String) },
      { type: "changed", seq: 1 },
    ]);
    expect(macSocket.messages).toEqual([{ type: "hello", seq: 0, epoch: expect.any(String) }]);
    airSocket.ws.close();
    macSocket.ws.close();
  });

  it("requires a websocket upgrade", async () => {
    const dev = await device();
    expect((await call("/v1/sync/ws", authed(dev))).status).toBe(426);
  });
});

describe("the server never needs plaintext", () => {
  it("syncs client-encrypted records it cannot read", async () => {
    const dev = await device();
    const other = await device(dev.userId);
    const marker = "Dear Anna, the secret garden is behind the third oak";
    const plaintext = new TextEncoder().encode(marker);

    // Client side: AES-256-GCM with a key the server never receives, record identity as AAD.
    const key = (await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"])) as CryptoKey;
    const id = crypto.randomUUID();
    const h = hlc(dev);
    const aad = new TextEncoder().encode(`matilde/v1|${dev.userId}|${id}|${T.body}|${h}|0|1`);
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, key, plaintext));
    const envelope = new Uint8Array(12 + sealed.length);
    envelope.set(nonce);
    envelope.set(sealed, 12);

    await push(dev, [change({ id, type: T.body, hlc: h, ct: b64(envelope) })]);

    // Nothing the server stored contains the plaintext.
    const stub = userSync(env, dev.userId);
    const stored = await runInDurableObject(stub, (_i: UserSync, state: DurableObjectState) =>
      state.storage.sql.exec<{ ct: ArrayBuffer }>("SELECT ct FROM records").toArray().map((r) => new Uint8Array(r.ct)),
    );
    const haystack = new TextDecoder("latin1").decode(stored[0]);
    expect(haystack.includes(marker)).toBe(false);
    expect(stored[0]).toEqual(envelope);

    // Another device with the key decrypts what it pulls.
    const [row] = (await pull(other)).rows;
    const bytes = Uint8Array.from(atob(row!.ct!), (ch) => ch.charCodeAt(0));
    const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: aad }, key, bytes.slice(12));
    expect(new TextDecoder().decode(opened)).toBe(marker);
  });

  it("accepts arbitrary bytes as ciphertext without parsing them", async () => {
    const dev = await device();
    const bytes = new Uint8Array(256).map((_, i) => i);
    const result = await push(dev, [change({ id: crypto.randomUUID(), type: 40, hlc: hlc(dev), ct: b64(bytes) })]);
    expect(result.accepted).toHaveLength(1);
    expect((await pull(dev)).rows[0]!.ct).toBe(b64(bytes));
  });
});
