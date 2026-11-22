// Consent page script for "Connect Matilde to an AI tool" (docs/mcp.md, "Consent flow").
// Runs in the person's browser. The Matilde key and the unwrapped account keys never leave it:
// only a copy of the keys sealed with a fresh grant secret is sent, together with that secret.
// Plain ES module, no dependencies, WebCrypto only. Tested in Node (server/test/node/connect.test.ts).
// After editing, run `pnpm run gen:mcp-assets` (the Worker serves the generated copy).

const enc = new TextEncoder();

// MARK: encoding

export function fields(...values) {
  const parts = values.map((v) => enc.encode(String(v)));
  const out = new Uint8Array(parts.reduce((n, p) => n + 2 + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out[at] = p.length >> 8;
    out[at + 1] = p.length & 0xff;
    out.set(p, at + 2);
    at += 2 + p.length;
  }
  return out;
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

export function b64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

export function unb64(text) {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function equal(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

// MARK: primitives

async function hkdf(ikm, salt, info) {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info: enc.encode(info) }, key, 256));
}

async function aesOpen(key, nonce, ct, aad) {
  const k = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, k, ct));
}

async function aesSeal(key, nonce, pt, aad) {
  const k = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  return new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, k, pt));
}

async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

async function hmac(key, message) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, message));
}

function random(n) {
  return crypto.getRandomValues(new Uint8Array(n));
}

// MARK: Matilde key

export class KeyError extends Error {
  constructor(code) {
    super(code);
    this.code = code; // "invalid" | "typo"
  }
}

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** "words" or "legacy" (MTLD- code), like SyncRecoveryKey.format(of:). */
export function keyFormat(text) {
  const t = text.trim();
  if (/^mtld/i.test(t)) return "legacy";
  const tokens = t.split(/[\s,]+/).filter(Boolean).filter((w) => !/^\d+[.)]?$/.test(w));
  if (tokens.some((w) => /\d/.test(w) && /[a-z]/i.test(w))) return "legacy";
  return "words";
}

async function legacySecret(text) {
  let s = text.toUpperCase().replace(/[\s-]/g, "");
  if (s.startsWith("MTLD")) s = s.slice(4);
  s = s.replace(/O/g, "0").replace(/[IL]/g, "1");
  if (s.length !== 52) throw new KeyError("invalid");
  const bits = [];
  for (const ch of s) {
    const v = CROCKFORD.indexOf(ch);
    if (v < 0) throw new KeyError("invalid");
    for (let b = 4; b >= 0; b--) bits.push((v >> b) & 1);
  }
  const key = new Uint8Array(32);
  for (let i = 0; i < 256; i++) key[i >> 3] |= bits[i] << (7 - (i & 7));
  const check = (bits[256] << 3) | (bits[257] << 2) | (bits[258] << 1) | bits[259];
  if ((await sha256(key))[0] >> 4 !== check) throw new KeyError("typo");
  return key;
}

/** The 12 words' entropy. `words` is the BIP39 English list (2048 entries). */
export async function wordsEntropy(text, words) {
  const tokens = text
    .toLowerCase()
    .split(/[\s,]+/)
    .map((w) => w.replace(/^\d+[.)]?/, "").replace(/[.)]+$/, ""))
    .filter(Boolean);
  if (tokens.length !== 12) throw new KeyError("invalid");
  const indices = tokens.map((token) => {
    const exact = words.indexOf(token);
    if (exact >= 0) return exact;
    if (token.length < 4) throw new KeyError("invalid");
    const matches = [];
    for (let i = 0; i < words.length && matches.length < 2; i++) if (words[i].startsWith(token)) matches.push(i);
    if (matches.length !== 1) throw new KeyError("invalid");
    return matches[0];
  });
  const bits = [];
  for (const index of indices) for (let b = 10; b >= 0; b--) bits.push((index >> b) & 1);
  const entropy = new Uint8Array(16);
  for (let i = 0; i < 128; i++) entropy[i >> 3] |= bits[i] << (7 - (i & 7));
  const check = (bits[128] << 3) | (bits[129] << 2) | (bits[130] << 1) | bits[131];
  if ((await sha256(entropy))[0] >> 4 !== check) throw new KeyError("typo");
  return entropy;
}

/** The recovery slot secret for a typed Matilde key (12 words or a legacy MTLD- code). */
export async function slotSecret(text, words) {
  if (keyFormat(text) === "legacy") return legacySecret(text);
  const entropy = await wordsEntropy(text, words);
  const key = await crypto.subtle.importKey("raw", entropy, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: enc.encode("matilde/matilde-key/v1"), info: enc.encode("matilde/matilde-key/v1/slot-secret") },
      key,
      256,
    ),
  );
}

// MARK: key slots

export async function unwrapSlot(secret, wrapped, userId, slot) {
  if (wrapped.length < 61 || wrapped[0] !== 1) throw new KeyError("invalid");
  const kek = await hkdf(secret, wrapped.subarray(1, 33), "matilde/v1/slot/" + slot.kind);
  return aesOpen(kek, wrapped.subarray(33, 45), wrapped.subarray(45), fields("matilde/v1/slot", userId, slot.slotId, slot.kind, String(slot.keyId)));
}

/**
 * Opens the account's key ring with the typed key: recovery slot, key check, older epochs.
 * `keys` is the /connect/verify response. Returns [{id, key}], current epoch first.
 */
export async function unlockRing(keys, text, words) {
  const secret = await slotSecret(text, words);
  const recovery = keys.slots.find((s) => s.kind === "recovery");
  if (!recovery) throw new KeyError("no_slot");
  let ak;
  try {
    ak = await unwrapSlot(secret, unb64(recovery.wrappedKey), keys.userId, recovery);
  } catch (error) {
    if (error instanceof KeyError) throw error;
    throw new KeyError("wrong");
  }
  const check = await hmac(ak, fields("matilde/v1/key-check", String(keys.keyId)));
  if (ak.length !== 32 || recovery.keyId !== keys.keyId || !keys.keyCheck || !equal(check, unb64(keys.keyCheck))) throw new KeyError("wrong");
  const ring = [{ id: keys.keyId, key: ak }];
  const previous = keys.slots.find((s) => s.kind === "previous-keys");
  if (previous) {
    const list = await unwrapSlot(ak, unb64(previous.wrappedKey), keys.userId, previous);
    for (let at = 0; at + 34 <= list.length; at += 34) ring.push({ id: (list[at] << 8) | list[at + 1], key: list.slice(at + 2, at + 34) });
  }
  return ring;
}

// MARK: grant wrap

export function encodeRing(ring) {
  const out = new Uint8Array(1 + ring.length * 34);
  out[0] = ring.length;
  ring.forEach((k, i) => {
    out[1 + i * 34] = k.id >> 8;
    out[2 + i * 34] = k.id & 0xff;
    out.set(k.key, 3 + i * 34);
  });
  return out;
}

/** Seals the ring for one connection. Returns what /connect/approve takes. */
export async function wrapForGrant(userId, ring, grantId = crypto.randomUUID(), secret = random(32)) {
  const salt = random(32);
  const nonce = random(12);
  const kek = await hkdf(secret, salt, "matilde/mcp/v1/grant");
  const ct = await aesSeal(kek, nonce, encodeRing(ring), fields("matilde/mcp/v1/grant", userId, grantId));
  return { grantId, grantSecret: b64(secret), wrappedRing: b64(concat(new Uint8Array([1]), salt, nonce, ct)) };
}

// MARK: page

async function post(path, body, login) {
  const headers = { "Content-Type": "application/json", "X-Matilde-Connect": "1" };
  if (login) headers["X-Matilde-Login"] = login;
  const res = await fetch(path, { method: "POST", headers, body: JSON.stringify(body), credentials: "same-origin" });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const error = new Error((data.error && data.error.message) || "Something went wrong. Try again.");
    error.code = data.error && data.error.code;
    throw error;
  }
  return data;
}

function init() {
  const $ = (id) => document.getElementById(id);
  const root = $("connect");
  const handle = root.dataset.handle;
  const state = { email: "", login: null, keys: null, ring: null };
  let wordsPromise = null;
  const words = () => (wordsPromise ??= fetch("/connect/bip39.txt").then((r) => r.text()).then((t) => t.trim().split("\n")));

  const show = (step) => {
    for (const el of document.querySelectorAll("[data-step]")) el.hidden = el.dataset.step !== step;
  };
  const error = (id, message) => {
    const el = $(id);
    el.textContent = message || "";
    el.hidden = !message;
  };
  const busy = (button, on) => {
    button.disabled = on;
    button.setAttribute("aria-busy", on ? "true" : "false");
  };
  const scopes = () => [...document.querySelectorAll("input[name=scope]:checked")].map((el) => el.value);
  const needsKey = () => scopes().some((s) => s !== "feedback");

  const continueButton = $("scopes-continue");
  const updateScopes = () => {
    continueButton.textContent = needsKey() ? "Continue" : "Connect";
    continueButton.disabled = scopes().length === 0;
  };
  for (const el of document.querySelectorAll("input[name=scope]")) el.addEventListener("change", updateScopes);
  updateScopes();

  async function approve(button, errorId) {
    busy(button, true);
    error(errorId, "");
    try {
      const body = { handle, scopes: scopes(), days: Number($("days").value) };
      if (needsKey()) Object.assign(body, await wrapForGrant(state.keys.userId, state.ring));
      const { redirectTo } = await post("/connect/approve", body, state.login);
      state.ring = null;
      show("done");
      window.location.assign(redirectTo);
    } catch (e) {
      error(errorId, e.message);
      busy(button, false);
    }
  }

  $("form-scopes").addEventListener("submit", (event) => {
    event.preventDefault();
    if (!needsKey()) return approve(continueButton, "scopes-error");
    show("email");
    $("email").focus();
  });

  $("form-email").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("email-continue");
    busy(button, true);
    error("email-error", "");
    try {
      state.email = $("email").value.trim();
      await post("/connect/code", { handle, email: state.email });
      $("code-email").textContent = state.email;
      show("code");
      $("code").focus();
    } catch (e) {
      error("email-error", e.message);
    }
    busy(button, false);
  });

  $("form-code").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("code-continue");
    busy(button, true);
    error("code-error", "");
    try {
      const data = await post("/connect/verify", { handle, email: state.email, code: $("code").value.replace(/\s/g, "") });
      state.login = data.login;
      state.keys = data;
      show("key");
      $("key").focus();
      words();
    } catch (e) {
      error("code-error", e.message);
    }
    busy(button, false);
  });

  $("form-key").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("key-continue");
    busy(button, true);
    error("key-error", "");
    const input = $("key");
    try {
      state.ring = await unlockRing(state.keys, input.value, await words());
      input.value = "";
    } catch (e) {
      const code = e && e.code;
      error(
        "key-error",
        code === "typo"
          ? "One of the words looks mistyped. Check them against your Matilde key."
          : code === "no_slot"
            ? "This account has no Matilde key yet. Turn on sync in the Matilde app first."
            : code === "invalid"
              ? "That doesn't look like a Matilde key: 12 words, or a code starting with MTLD."
              : "That key doesn't open this account.",
      );
      busy(button, false);
      return;
    }
    await approve(button, "key-error");
  });

  for (const el of document.querySelectorAll("[data-deny]")) {
    el.addEventListener("click", async () => {
      try {
        const { redirectTo } = await post("/connect/deny", { handle });
        window.location.assign(redirectTo);
      } catch (e) {
        el.closest("section").querySelector(".error").textContent = e.message;
      }
    });
  }
  show("scopes");
}

if (typeof document !== "undefined" && document.getElementById("connect")) init();
