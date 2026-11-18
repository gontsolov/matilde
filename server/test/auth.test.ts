import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { memoryOutbox } from "../src/auth/mailer";
import { ipPrefix } from "../src/auth/ratelimit";
import { REFRESH_RETRY_GRACE_MS, refreshSession } from "../src/auth/sessions";
import { verifyAccessToken } from "../src/auth/tokens";
import { cleanupDirectory } from "../src/maintenance";
import { authed, call, change, hlc, pull, push, T } from "./helpers";

let ipCounter = 0;
/** A fresh /24 per test so IP limits don't leak between tests. */
function freshIp(): string {
  ipCounter += 1;
  return `10.${Math.floor(ipCounter / 250)}.${ipCounter % 250}.7`;
}

function post(path: string, body: unknown, ip = freshIp(), token?: string) {
  const headers: Record<string, string> = { "Content-Type": "application/json", "CF-Connecting-IP": ip };
  if (token) headers.Authorization = `Bearer ${token}`;
  return call(path, { method: "POST", headers, body: JSON.stringify(body) });
}

function lastCode(to: string): string {
  const mail = [...memoryOutbox()].reverse().find((m) => m.to === to);
  if (!mail) throw new Error(`no mail to ${to}`);
  return /\b(\d{6})\b/.exec(mail.text)![1]!;
}

const email = () => `writer-${crypto.randomUUID().slice(0, 8)}@example.com`;

interface Tokens {
  accessToken: string;
  refreshToken: string;
  sessionId: string;
  userId: string;
  isNewAccount: boolean;
}

async function signIn(address: string, deviceId: string = crypto.randomUUID(), platform = "macos"): Promise<Tokens & { deviceId: string }> {
  const ip = freshIp();
  expect((await post("/v1/auth/email/start", { email: address }, ip)).status).toBe(202);
  const res = await post("/v1/auth/email/verify", { email: address, code: lastCode(address.trim().toLowerCase()), deviceId, platform }, ip);
  expect(res.status).toBe(200);
  return { ...((await res.json()) as Tokens), deviceId };
}

beforeEach(() => {
  memoryOutbox().length = 0;
});

describe("email code sign-in", () => {
  it("creates an account on first sign-in and reuses it afterwards", async () => {
    const address = email();
    const first = await signIn(address);
    expect(first.isNewAccount).toBe(true);
    const claims = await verifyAccessToken(env, first.accessToken);
    expect(claims).toEqual({ userId: first.userId, sessionId: first.sessionId, deviceId: first.deviceId });

    const second = await signIn(`  ${address.toUpperCase()} `);
    expect(second.isNewAccount).toBe(false);
    expect(second.userId).toBe(first.userId);
    expect(second.sessionId).not.toBe(first.sessionId);
  });

  it("stores only hashes of the address and the code", async () => {
    const address = email();
    await post("/v1/auth/email/start", { email: address });
    const code = lastCode(address);
    const rows = await env.DB.prepare("SELECT * FROM email_codes").all();
    const dump = JSON.stringify(rows.results);
    expect(dump).not.toContain(address);
    expect(dump).not.toContain(code);
  });

  it("rejects a wrong code and burns the code after five attempts", async () => {
    const address = email();
    const ip = freshIp();
    await post("/v1/auth/email/start", { email: address }, ip);
    const code = lastCode(address);
    const wrong = code === "000000" ? "111111" : "000000";
    const deviceId = crypto.randomUUID();
    for (let i = 0; i < 5; i++) {
      const res = await post("/v1/auth/email/verify", { email: address, code: wrong, deviceId, platform: "macos" }, ip);
      expect(res.status).toBe(400);
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe("invalid_code");
    }
    const late = await post("/v1/auth/email/verify", { email: address, code, deviceId, platform: "macos" }, ip);
    expect(late.status).toBe(400);
  });

  it("accepts a code only once", async () => {
    const address = email();
    const ip = freshIp();
    await post("/v1/auth/email/start", { email: address }, ip);
    const code = lastCode(address);
    const body = { email: address, code, deviceId: crypto.randomUUID(), platform: "macos" };
    expect((await post("/v1/auth/email/verify", body, ip)).status).toBe(200);
    expect((await post("/v1/auth/email/verify", body, ip)).status).toBe(400);
  });

  it("expires codes after ten minutes", async () => {
    const address = email();
    await post("/v1/auth/email/start", { email: address });
    await env.DB.prepare("UPDATE email_codes SET expires_at = ?").bind(Date.now() - 1).run();
    const res = await post("/v1/auth/email/verify", { email: address, code: lastCode(address), deviceId: crypto.randomUUID(), platform: "macos" });
    expect(res.status).toBe(400);
  });

  it("replaces the previous code when a new one is requested", async () => {
    const address = email();
    const ip = freshIp();
    await post("/v1/auth/email/start", { email: address }, ip);
    const old = lastCode(address);
    await post("/v1/auth/email/start", { email: address }, ip);
    const current = lastCode(address);
    if (old !== current) {
      expect((await post("/v1/auth/email/verify", { email: address, code: old, deviceId: crypto.randomUUID(), platform: "macos" }, ip)).status).toBe(400);
    }
    expect((await post("/v1/auth/email/verify", { email: address, code: current, deviceId: crypto.randomUUID(), platform: "macos" }, ip)).status).toBe(200);
  });

  it("rate-limits codes per address", async () => {
    const address = email();
    for (let i = 0; i < 3; i++) expect((await post("/v1/auth/email/start", { email: address })).status).toBe(202);
    const limited = await post("/v1/auth/email/start", { email: address });
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("Retry-After"))).toBeGreaterThan(0);
    expect(memoryOutbox()).toHaveLength(3);
  });

  it("rate-limits codes per network", async () => {
    const ip = freshIp();
    for (let i = 0; i < 20; i++) expect((await post("/v1/auth/email/start", { email: email() }, ip)).status).toBe(202);
    // Same /24, different host.
    const sameNetwork = ip.replace(/\.\d+$/, ".99");
    expect((await post("/v1/auth/email/start", { email: email() }, sameNetwork)).status).toBe(429);
  });

  it("validates input", async () => {
    expect((await post("/v1/auth/email/start", { email: "not-an-email" })).status).toBe(400);
    const address = email();
    await post("/v1/auth/email/start", { email: address });
    const code = lastCode(address);
    expect((await post("/v1/auth/email/verify", { email: address, code, deviceId: "nope", platform: "macos" })).status).toBe(400);
    expect((await post("/v1/auth/email/verify", { email: address, code, deviceId: crypto.randomUUID(), platform: "amiga" })).status).toBe(400);
  });

  it("groups IPv6 addresses by /48 and IPv4 by /24", () => {
    expect(ipPrefix("2001:db8:abcd:12::1")).toBe("2001:db8:abcd::/48");
    expect(ipPrefix("2001:db8::1")).toBe("2001:db8:0::/48");
    expect(ipPrefix("203.0.113.45")).toBe("203.0.113.0/24");
  });
});

describe("refresh tokens", () => {
  it("rotates on every use", async () => {
    const s = await signIn(email());
    const res = await post("/v1/auth/refresh", { refreshToken: s.refreshToken });
    expect(res.status).toBe(200);
    const next = (await res.json()) as Tokens;
    expect(next.refreshToken).not.toBe(s.refreshToken);
    expect(next.sessionId).toBe(s.sessionId);
    expect(await verifyAccessToken(env, next.accessToken)).toMatchObject({ userId: s.userId, sessionId: s.sessionId });
    const stored = await env.DB.prepare("SELECT refresh_hash FROM sessions WHERE id = ?").bind(s.sessionId).first<{ refresh_hash: string }>();
    expect(next.refreshToken).not.toContain(stored!.refresh_hash);
  });

  it("revokes the session when a rotated token is reused", async () => {
    const s = await signIn(email());
    const a = (await (await post("/v1/auth/refresh", { refreshToken: s.refreshToken })).json()) as Tokens;
    const b = (await (await post("/v1/auth/refresh", { refreshToken: a.refreshToken })).json()) as Tokens;
    // The very first token is two rotations old: theft.
    const reuse = await post("/v1/auth/refresh", { refreshToken: s.refreshToken });
    expect(reuse.status).toBe(401);
    expect(((await reuse.json()) as { error: { code: string } }).error.code).toBe("refresh_token_reused");
    // The legitimate latest token no longer works either.
    expect((await post("/v1/auth/refresh", { refreshToken: b.refreshToken })).status).toBe(401);
    expect(await env.DB.prepare("SELECT 1 FROM sessions WHERE id = ?").bind(s.sessionId).first()).toBeNull();
  });

  it("allows a retry with the previous token for a few seconds, then treats it as reuse", async () => {
    const s = await signIn(email());
    const now = Date.now();
    const lost = await refreshSession(env, s.refreshToken, now);
    // The response got lost; the client retries with the same token.
    const retry = await refreshSession(env, s.refreshToken, now + 1000);
    expect(retry.sessionId).toBe(s.sessionId);
    // The token from the lost response is now dead, the retry's token works.
    const fresh = await refreshSession(env, retry.refreshToken, now + 2000);
    await expect(refreshSession(env, lost.refreshToken, now + 3000)).rejects.toMatchObject({ code: "refresh_token_reused" });
    await expect(refreshSession(env, fresh.refreshToken, now + 4000)).rejects.toMatchObject({ status: 401 });

    const t = await signIn(email());
    await refreshSession(env, t.refreshToken, now);
    await expect(refreshSession(env, t.refreshToken, now + REFRESH_RETRY_GRACE_MS + 1)).rejects.toMatchObject({ code: "refresh_token_reused" });
  });

  it("rejects malformed, unknown and expired tokens", async () => {
    expect((await post("/v1/auth/refresh", { refreshToken: "garbage" })).status).toBe(401);
    expect((await post("/v1/auth/refresh", { refreshToken: `mrt1.${crypto.randomUUID()}.${"A".repeat(43)}` })).status).toBe(401);
    const s = await signIn(email());
    await env.DB.prepare("UPDATE sessions SET expires_at = ? WHERE id = ?").bind(Date.now() - 1, s.sessionId).run();
    expect((await post("/v1/auth/refresh", { refreshToken: s.refreshToken })).status).toBe(401);
  });
});

describe("devices and revocation", () => {
  it("lists devices and revokes one", async () => {
    const address = email();
    const mac = await signIn(address, crypto.randomUUID(), "macos");
    const phone = await signIn(address, crypto.randomUUID(), "ios");
    const list = await call("/v1/devices", authed({ token: mac.accessToken }));
    const { devices } = (await list.json()) as { devices: { sessionId: string; platform: string; current: boolean }[] };
    expect(devices.map((d) => d.platform)).toEqual(["macos", "ios"]);
    expect(devices.find((d) => d.current)!.sessionId).toBe(mac.sessionId);

    const revoke = await call(`/v1/devices/${phone.sessionId}`, authed({ token: mac.accessToken }, { method: "DELETE" }));
    expect(revoke.status).toBe(204);
    expect((await post("/v1/auth/refresh", { refreshToken: phone.refreshToken })).status).toBe(401);
    // A revoked session can't act on others, even with a still-valid access token.
    const fromRevoked = await call(`/v1/devices/${mac.sessionId}`, authed({ token: phone.accessToken }, { method: "DELETE" }));
    expect(fromRevoked.status).toBe(401);
  });

  it("closes a revoked device's sockets", async () => {
    const address = email();
    const mac = await signIn(address);
    const air = await signIn(address);
    const res = await call("/v1/sync/ws", authed({ token: air.accessToken }, { headers: { Upgrade: "websocket" } }));
    const ws = res.webSocket!;
    const closed = new Promise<number>((resolve) => ws.addEventListener("close", (e) => resolve(e.code)));
    ws.accept();
    await call(`/v1/devices/${air.sessionId}`, authed({ token: mac.accessToken }, { method: "DELETE" }));
    expect(await closed).toBe(4001);
  });

  it("can't revoke another account's sessions", async () => {
    const anna = await signIn(email());
    const ben = await signIn(email());
    const res = await call(`/v1/devices/${ben.sessionId}`, authed({ token: anna.accessToken }, { method: "DELETE" }));
    expect(res.status).toBe(404);
    expect((await post("/v1/auth/refresh", { refreshToken: ben.refreshToken })).status).toBe(200);
  });

  it("stores the encrypted device name opaquely", async () => {
    const mac = await signIn(email());
    const nameCt = btoa("ciphertext-of-a-device-name");
    const res = await call(`/v1/devices/${mac.sessionId}`, authed({ token: mac.accessToken }, { method: "PATCH", body: JSON.stringify({ deviceNameCt: nameCt }) }));
    expect(res.status).toBe(204);
    const { devices } = (await (await call("/v1/devices", authed({ token: mac.accessToken }))).json()) as { devices: { nameCt: string }[] };
    expect(devices[0]!.nameCt).toBe(nameCt);
  });

  it("signing in again on the same device replaces its session", async () => {
    const address = email();
    const deviceId = crypto.randomUUID();
    const first = await signIn(address, deviceId);
    const second = await signIn(address, deviceId);
    expect((await post("/v1/auth/refresh", { refreshToken: first.refreshToken })).status).toBe(401);
    const { devices } = (await (await call("/v1/devices", authed({ token: second.accessToken }))).json()) as { devices: unknown[] };
    expect(devices).toHaveLength(1);
  });

  it("limits an account to ten devices", async () => {
    const address = email();
    // Per-address code limits would otherwise stop this loop; clear them for the test.
    const clearLimits = () => env.DB.prepare("DELETE FROM rate_counters").run();
    for (let i = 0; i < 10; i++) {
      await clearLimits();
      await signIn(address);
    }
    const ip = freshIp();
    await clearLimits();
    await post("/v1/auth/email/start", { email: address }, ip);
    const res = await post("/v1/auth/email/verify", { email: address, code: lastCode(address), deviceId: crypto.randomUUID(), platform: "macos" }, ip);
    expect(res.status).toBe(403);
  });

  it("signs out", async () => {
    const s = await signIn(email());
    expect((await post("/v1/auth/logout", {}, freshIp(), s.accessToken)).status).toBe(204);
    expect((await post("/v1/auth/refresh", { refreshToken: s.refreshToken })).status).toBe(401);
  });
});

describe("sync with real sessions", () => {
  it("lets two devices of one account sync and keeps accounts apart", async () => {
    const address = email();
    const mac = await signIn(address);
    const air = await signIn(address);
    const other = await signIn(email());
    const macDev = { userId: mac.userId, deviceId: mac.deviceId, sessionId: mac.sessionId, token: mac.accessToken };
    const airDev = { userId: air.userId, deviceId: air.deviceId, sessionId: air.sessionId, token: air.accessToken };
    const otherDev = { userId: other.userId, deviceId: other.deviceId, sessionId: other.sessionId, token: other.accessToken };
    const id = crypto.randomUUID();
    await push(macDev, [change({ id, type: T.draft, hlc: hlc(macDev) })]);
    expect((await pull(airDev)).rows.map((r) => r.id)).toEqual([id]);
    expect((await pull(otherDev)).rows).toEqual([]);
  });
});

describe("key slots", () => {
  it("stores wrapped keys opaquely with compare-and-swap on the key id", async () => {
    const s = await signIn(email());
    const auth = { token: s.accessToken };
    const empty = await (await call("/v1/keys", authed(auth))).json();
    expect(empty).toEqual({ keyId: null, keyCheck: null, slots: [] });

    const slot = { slotId: crypto.randomUUID(), kind: "recovery", wrappedKey: btoa("wrapped-account-key-bytes") };
    const put = (body: unknown) => call("/v1/keys", authed(auth, { method: "PUT", body: JSON.stringify(body) }));
    expect((await put({ expectedKeyId: null, keyId: 1, keyCheck: btoa("check"), slots: [slot] })).status).toBe(200);
    // A second device racing to create the first key loses.
    expect((await put({ expectedKeyId: null, keyId: 1, keyCheck: btoa("other"), slots: [slot] })).status).toBe(409);
    // Rotation names the key it replaces.
    const passphrase = { slotId: crypto.randomUUID(), kind: "passphrase", params: '{"m":65536,"t":3}', wrappedKey: btoa("w2") };
    expect((await put({ expectedKeyId: 1, keyId: 2, keyCheck: btoa("check2"), slots: [slot, passphrase] })).status).toBe(200);
    const stored = (await (await call("/v1/keys", authed(auth))).json()) as { keyId: number; slots: { kind: string; keyId: number }[] };
    expect(stored.keyId).toBe(2);
    expect(stored.slots.map((x) => [x.kind, x.keyId]).sort()).toEqual([["passphrase", 2], ["recovery", 2]]);
  });
});

describe("account deletion", () => {
  it("deletes records, blobs, sessions and the account, and stops old tokens writing", async () => {
    const address = email();
    const s = await signIn(address);
    const dev = { userId: s.userId, deviceId: s.deviceId, sessionId: s.sessionId, token: s.accessToken };
    const blobId = crypto.randomUUID();
    await call(`/v1/blobs/${blobId}`, authed(dev, { method: "PUT", body: new Uint8Array(8), headers: { "Content-Length": "8" } }));
    await push(dev, [change({ id: crypto.randomUUID(), type: T.asset, hlc: hlc(dev), blobId })]);

    const wrongConfirm = await call("/v1/account", authed(dev, { method: "DELETE", body: JSON.stringify({ confirm: "yes" }) }));
    expect(wrongConfirm.status).toBe(400);
    const res = await call("/v1/account", authed(dev, { method: "DELETE", body: JSON.stringify({ confirm: "delete my account" }) }));
    expect(res.status).toBe(204);

    expect((await env.BLOBS.list({ prefix: `u/${s.userId}/` })).objects).toHaveLength(0);
    expect(await env.DB.prepare("SELECT 1 FROM accounts WHERE id = ?").bind(s.userId).first()).toBeNull();
    expect(await env.DB.prepare("SELECT 1 FROM sessions WHERE account_id = ?").bind(s.userId).first()).toBeNull();
    expect((await post("/v1/auth/refresh", { refreshToken: s.refreshToken })).status).toBe(401);
    // The access token is still unexpired, but the user's store refuses it.
    const late = await call(
      "/v1/sync/push",
      authed(dev, { method: "POST", body: JSON.stringify({ changes: [change({ id: crypto.randomUUID(), type: T.draft, hlc: hlc(dev) })] }) }),
    );
    expect(late.status).toBe(410);

    // Signing in with the same address afterwards creates a brand-new account.
    const again = await signIn(address);
    expect(again.isNewAccount).toBe(true);
    expect(again.userId).not.toBe(s.userId);
  });
});

describe("maintenance", () => {
  it("removes expired codes, counters and sessions", async () => {
    const s = await signIn(email());
    await post("/v1/auth/email/start", { email: email() });
    await cleanupDirectory(env, Date.now() + 100 * 24 * 3600 * 1000);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM email_codes").first("n")).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM rate_counters").first("n")).toBe(0);
    expect(await env.DB.prepare("SELECT 1 FROM sessions WHERE id = ?").bind(s.sessionId).first()).toBeNull();
  });
});
