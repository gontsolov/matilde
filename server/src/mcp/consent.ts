// The consent page on the MCP host (mcp.matilde.page): /authorize and the /connect/* steps it
// drives. The person picks permissions, proves the address with an email code, and types their
// Matilde key; the key is unwrapped in the browser (web/connect.js) and only a grant-sealed copy
// of the key ring reaches the server. See docs/mcp.md.

import { AuthorizationError, CimdFetchError, type AuthRequest, type ConsentDescription, type OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { consumeEmailCode, startEmailSignIn } from "../auth/email";
import { RateLimitError } from "../auth/ratelimit";
import type { Env } from "../env";
import { base64ToBytes, bytesToBase64, bytesToBase64Url, HttpError, randomBytes, sha256Hex, timingSafeEqual, UUID_RE } from "../util";
import { keyCheck, unwrapRing } from "./crypto";
import { DEFAULT_DURATION_DAYS, DEFAULT_SCOPES, DURATIONS_DAYS, GRANT_LIMITS, type GrantProps, needsKey, SCOPES } from "./grants";
import { BIP39_WORDS, CONNECT_JS } from "./web/assets.generated";

export type McpEnv = Env & { OAUTH_KV: KVNamespace; OAUTH_PROVIDER: OAuthHelpers };

const SCOPE_TEXT: Record<string, { label: string; detail: string }> = {
  "notes:read": { label: "Read your notes", detail: "List, search and read notes and their comments." },
  "notes:comment": { label: "Comment on your notes", detail: "Add comments to a passage. The note itself stays as it is." },
  "notes:create": { label: "Create notes", detail: "Add new notes. Existing notes aren't changed." },
  "notes:edit": { label: "Edit your notes", detail: "Change the text of existing notes. Off unless you turn it on." },
  feedback: { label: "Send feedback about Matilde", detail: "Pass on a bug report or idea when you ask it to. Needs no access to notes." },
};

const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

const CSS = `:root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#fbfaf7;--card:#fff;--line:#e3e1dc;--accent:#1f3a5f;--warn:#8a4b00}
@media (prefers-color-scheme:dark){:root{--fg:#f2f2f2;--muted:#a1a1a6;--bg:#1c1c1e;--card:#2c2c2e;--line:#3a3a3c;--accent:#9ec3ff;--warn:#ffc46b}}
*{box-sizing:border-box}body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--bg);color:var(--fg)}
main{max-width:30rem;margin:3rem auto;padding:0 1.25rem}h1{font-size:1.4rem;margin:0 0 .5rem}p{margin:.5rem 0}.muted{color:var(--muted);font-size:.9rem}
section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:1.25rem;margin-top:1rem}
label.scope{display:flex;gap:.6rem;align-items:flex-start;padding:.5rem 0;border-top:1px solid var(--line)}label.scope:first-of-type{border-top:0}
label.scope span{display:block}label.scope small{color:var(--muted)}input[type=email],input[type=text],textarea,select{width:100%;font:inherit;padding:.55rem .7rem;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg)}
textarea{min-height:5.5rem;resize:vertical}.row{display:flex;gap:.6rem;margin-top:1rem}button{font:inherit;padding:.55rem 1rem;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:var(--bg)}button:disabled{opacity:.5;cursor:default}.error{color:#c0392b;margin-top:.5rem}.warn{color:var(--warn)}
code{font-size:.9em}`;

const escape = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);

function page(title: string, body: string, headers?: Headers, status = 200): Response {
  const h = new Headers(headers);
  h.set("Content-Type", "text/html; charset=utf-8");
  h.set("Content-Security-Policy", CSP);
  h.set("Cache-Control", "no-store");
  h.set("Referrer-Policy", "no-referrer");
  h.set("X-Content-Type-Options", "nosniff");
  h.set("X-Frame-Options", "DENY");
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)}</title><link rel="stylesheet" href="/connect/app.css"></head><body><main>${body}</main></body></html>`;
  return new Response(html, { status, headers: h });
}

function errorPage(message: string, status = 400): Response {
  return page("Matilde", `<h1>This connection can't continue</h1><p>${escape(message)}</p><p class="muted">Start connecting again from your AI tool.</p>`, undefined, status);
}

function json(body: unknown, status = 200, headers?: Headers): Response {
  const h = new Headers(headers);
  h.set("Content-Type", "application/json");
  h.set("Cache-Control", "no-store");
  return new Response(JSON.stringify(body), { status, headers: h });
}

const fail = (status: number, code: string, message: string) => json({ error: { code, message } }, status);

export function consentPage(info: ConsentDescription, handle: string, headers: Headers): Response {
  const name = escape(info.clientName);
  const verified = info.clientDomain
    ? `<p class="muted">Verified domain: <strong>${escape(info.clientDomain)}</strong></p>`
    : `<p class="muted">The name “${name}” is the tool's own description and isn't verified. Continue only if you started this from that tool.</p>`;
  const loopback = info.redirectIsLoopback
    ? `<p class="warn">This connection goes to an app on this computer. Any program running here could receive it, whatever name it gives.</p>`
    : "";
  const scopes = SCOPES.map((s) => {
    const t = SCOPE_TEXT[s]!;
    const checked = (DEFAULT_SCOPES as readonly string[]).includes(s) ? " checked" : "";
    return `<label class="scope"><input type="checkbox" name="scope" value="${s}"${checked}><span>${escape(t.label)}<small>${escape(t.detail)}</small></span></label>`;
  }).join("");
  const days = DURATIONS_DAYS.map((d) => `<option value="${d}"${d === DEFAULT_DURATION_DAYS ? " selected" : ""}>${d === 1 ? "1 day" : `${d} days`}</option>`).join("");
  const deny = `<button type="button" data-deny>Don't connect</button>`;
  const body = `<div id="connect" data-handle="${escape(handle)}">
<h1>Connect ${name} to Matilde</h1>${verified}
<p class="muted">Sends you back to <strong>${escape(info.redirectHost)}</strong>.</p>${loopback}
<section data-step="scopes"><form id="form-scopes">
<p>What may ${name} do?</p>${scopes}
<p><label for="days">Connection ends after</label> <select id="days">${days}</select></p>
<p class="muted">While this connection is active, the Matilde server can decrypt your notes so ${name} can work with them, and ${name} sees what it reads. Your Matilde key stays in this browser. You can end the connection at any time in Matilde's settings, under Connected AI tools.</p>
<p class="error" id="scopes-error" hidden></p>
<div class="row"><button class="primary" id="scopes-continue" type="submit">Continue</button>${deny}</div></form></section>
<section data-step="email" hidden><form id="form-email">
<p><label for="email">The email address you use for Matilde sync</label></p><input id="email" type="email" autocomplete="email" required>
<p class="error" id="email-error" hidden></p>
<div class="row"><button class="primary" id="email-continue" type="submit">Send code</button>${deny}</div></form></section>
<section data-step="code" hidden><form id="form-code">
<p><label for="code">Enter the 6-digit code sent to <strong id="code-email"></strong></label></p><input id="code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="7" required>
<p class="error" id="code-error" hidden></p>
<div class="row"><button class="primary" id="code-continue" type="submit">Continue</button>${deny}</div></form></section>
<section data-step="key" hidden><form id="form-key">
<p><label for="key">Your Matilde key</label></p><textarea id="key" autocomplete="off" autocapitalize="off" spellcheck="false" required></textarea>
<p class="muted">The 12 words (or the code starting with MTLD) Matilde gave you when you turned on sync. It's checked here in the browser and never sent anywhere.</p>
<p class="error" id="key-error" hidden></p>
<div class="row"><button class="primary" id="key-continue" type="submit">Connect</button>${deny}</div></form></section>
<section data-step="done" hidden><p>Connected. Taking you back to ${name}…</p></section>
<noscript><p class="error">Connecting needs JavaScript: your key is checked in this browser.</p></noscript>
</div><script type="module" src="/connect/app.js"></script>`;
  return page(`Connect ${info.clientName} to Matilde`, body, headers);
}

const ASSET_HEADERS = { "Cache-Control": "public, max-age=300", "X-Content-Type-Options": "nosniff" };

async function body(request: Request): Promise<Record<string, unknown>> {
  if (request.headers.get("X-Matilde-Connect") !== "1") throw new HttpError(403, "forbidden", "missing X-Matilde-Connect header");
  if (!(request.headers.get("Content-Type") ?? "").startsWith("application/json")) throw new HttpError(415, "unsupported_media_type");
  const text = await request.text();
  if (text.length > 64 * 1024) throw new HttpError(413, "too_large");
  try {
    const parsed = JSON.parse(text);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "invalid_request", "body must be a JSON object");
}

const ip = (request: Request) => request.headers.get("CF-Connecting-IP") ?? "unknown";

/** The provider's default handler on the MCP host: everything that isn't /mcp or an OAuth endpoint. */
export async function consentFetch(request: Request, env: McpEnv, nowMs = Date.now()): Promise<Response> {
  const url = new URL(request.url);
  try {
    if (request.method === "GET" || request.method === "HEAD") {
      switch (url.pathname) {
        case "/":
          return page("Matilde for AI tools", `<h1>Matilde for AI tools</h1><p>This is the address AI tools connect to: <code>${escape(url.origin)}/mcp</code>.</p><p class="muted">See matilde.page for how to connect Claude, ChatGPT or Cursor.</p>`);
        case "/authorize":
          return await authorize(request, env);
        case "/connect/app.js":
          return new Response(CONNECT_JS, { headers: { ...ASSET_HEADERS, "Content-Type": "text/javascript; charset=utf-8" } });
        case "/connect/app.css":
          return new Response(CSS, { headers: { ...ASSET_HEADERS, "Content-Type": "text/css; charset=utf-8" } });
        case "/connect/bip39.txt":
          return new Response(BIP39_WORDS, { headers: { ...ASSET_HEADERS, "Content-Type": "text/plain; charset=utf-8" } });
      }
    }
    if (request.method === "POST") {
      switch (url.pathname) {
        case "/connect/code":
          return await sendCode(request, env, nowMs);
        case "/connect/verify":
          return await verify(request, env, nowMs);
        case "/connect/approve":
          return await approve(request, env, nowMs);
        case "/connect/deny":
          return await deny(request, env);
      }
    }
    return fail(404, "not_found", "not found");
  } catch (error) {
    if (error instanceof AuthorizationError) {
      if (url.pathname === "/authorize") {
        return error.redirectTo ? Response.redirect(error.redirectTo, 302) : errorPage(error.description);
      }
      return fail(400, error.code, "This page has expired. Start connecting again from your AI tool.");
    }
    if (error instanceof CimdFetchError) return errorPage("The AI tool's description couldn't be loaded.");
    if (error instanceof RateLimitError) return fail(429, "rate_limited", "Too many attempts. Try again later.");
    if (error instanceof HttpError) {
      const message = error.code === "invalid_code" ? "That code is wrong or has expired." : error.message;
      const h = new Headers(error.headers);
      return json({ error: { code: error.code, message } }, error.status, h);
    }
    throw error;
  }
}

async function authorize(request: Request, env: McpEnv): Promise<Response> {
  const helpers = env.OAUTH_PROVIDER;
  let authRequest: AuthRequest;
  try {
    authRequest = await helpers.parseAuthRequest(request);
  } catch (error) {
    if (error instanceof AuthorizationError || error instanceof CimdFetchError) throw error;
    return errorPage(error instanceof Error ? error.message : "invalid authorization request");
  }
  const info = await helpers.describeConsent(authRequest);
  const { handle, headers } = await helpers.beginConsent(authRequest);
  return consentPage(info, handle, headers);
}

async function sendCode(request: Request, env: McpEnv, nowMs: number): Promise<Response> {
  const b = await body(request);
  await startEmailSignIn(env, b.email, ip(request), nowMs);
  return json({ ok: true });
}

async function verify(request: Request, env: McpEnv, nowMs: number): Promise<Response> {
  const b = await body(request);
  const email = await consumeEmailCode(env, b.email, b.code, ip(request), nowMs);
  const identity = await env.DB.prepare("SELECT account_id FROM identities WHERE provider = 'email' AND subject = ?").bind(email).first<{ account_id: string }>();
  if (!identity) return fail(404, "no_account", "There's no Matilde sync account for this address. Turn on sync in the Matilde app first.");
  const userId = identity.account_id;
  const account = await env.DB.prepare("SELECT key_id, key_check FROM accounts WHERE id = ?").bind(userId).first<{ key_id: number | null; key_check: string | null }>();
  if (!account || account.key_id === null || !account.key_check) return fail(409, "no_key", "This account has no Matilde key yet. Turn on sync in the Matilde app first.");
  const slots = await env.DB.prepare("SELECT slot_id, kind, key_id, params, wrapped_key FROM key_slots WHERE account_id = ? ORDER BY slot_id")
    .bind(userId)
    .all<{ slot_id: string; kind: string; key_id: number; params: string | null; wrapped_key: string }>();
  const login = bytesToBase64Url(randomBytes(32));
  await env.DB.prepare("INSERT INTO mcp_logins (token_hash, user_id, expires_at) VALUES (?, ?, ?)")
    .bind(await sha256Hex(login), userId, nowMs + GRANT_LIMITS.loginTtlMs)
    .run();
  return json({
    login,
    userId,
    keyId: account.key_id,
    keyCheck: account.key_check,
    slots: slots.results.map((s) => ({ slotId: s.slot_id, kind: s.kind, keyId: s.key_id, params: s.params, wrappedKey: s.wrapped_key })),
  });
}

function parseApproval(b: Record<string, unknown>): { handle: string; scopes: string[]; days: number } {
  if (typeof b.handle !== "string" || !b.handle) throw new HttpError(400, "invalid_request", "missing handle");
  if (!Array.isArray(b.scopes) || b.scopes.length === 0) throw new HttpError(400, "invalid_request", "choose at least one permission");
  const scopes = [...new Set(b.scopes)];
  if (!scopes.every((s) => typeof s === "string" && (SCOPES as readonly string[]).includes(s))) throw new HttpError(400, "invalid_request", "unknown permission");
  const days = Number(b.days);
  if (!(DURATIONS_DAYS as readonly number[]).includes(days)) throw new HttpError(400, "invalid_request", "unknown duration");
  return { handle: b.handle, scopes: SCOPES.filter((s) => scopes.includes(s)), days };
}

async function approve(request: Request, env: McpEnv, nowMs: number): Promise<Response> {
  const b = await body(request);
  const { handle, scopes, days } = parseApproval(b);
  let userId: string;
  let grantId: string;
  let grantSecret: string | undefined;
  let wrapped: Uint8Array | null = null;

  if (needsKey(scopes)) {
    const login = request.headers.get("X-Matilde-Login") ?? "";
    if (!login) throw new HttpError(401, "login_required", "Confirm your email address first.");
    const row = await env.DB.prepare("DELETE FROM mcp_logins WHERE token_hash = ? AND expires_at > ? RETURNING user_id")
      .bind(await sha256Hex(login), nowMs)
      .first<{ user_id: string }>();
    if (!row) throw new HttpError(401, "login_expired", "This sign-in has expired. Start connecting again from your AI tool.");
    userId = row.user_id;
    if (typeof b.grantId !== "string" || !UUID_RE.test(b.grantId)) throw new HttpError(400, "invalid_request", "invalid grant id");
    grantId = b.grantId;
    const secret = typeof b.grantSecret === "string" ? base64ToBytes(b.grantSecret) : null;
    wrapped = typeof b.wrappedRing === "string" ? base64ToBytes(b.wrappedRing) : null;
    if (!secret || secret.length !== 32 || !wrapped || wrapped.length > 4096) throw new HttpError(400, "invalid_request", "invalid key material");
    // Check that the browser unwrapped this account's current key: the ring must open with the
    // grant secret and its first key must match the account's key check.
    const account = await env.DB.prepare("SELECT key_id, key_check FROM accounts WHERE id = ?").bind(userId).first<{ key_id: number | null; key_check: string | null }>();
    let ok = false;
    try {
      const ring = await unwrapRing(secret, userId, grantId, wrapped);
      const current = ring.keys[0];
      ok = !!account && !!account.key_check && !!current && current.id === account.key_id && timingSafeEqual(bytesToBase64(await keyCheck(current.key, current.id)), account.key_check);
    } catch {
      ok = false;
    }
    if (!ok) throw new HttpError(400, "wrong_key", "That key doesn't open this account.");
    grantSecret = b.grantSecret as string;
    const active = await env.DB.prepare("SELECT COUNT(*) AS n FROM mcp_grants WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ?")
      .bind(userId, nowMs)
      .first<{ n: number }>();
    if ((active?.n ?? 0) >= GRANT_LIMITS.maxActivePerUser) {
      throw new HttpError(409, "too_many_connections", "You have too many connected AI tools. End one in Matilde's settings first.");
    }
  } else {
    // Feedback only: no account involved; the connection can't reach any notes.
    userId = crypto.randomUUID();
    grantId = crypto.randomUUID();
  }

  const helpers = env.OAUTH_PROVIDER;
  const approved = await helpers.approveConsent(request, handle, { scope: scopes });
  const info = await helpers.describeConsent(approved.request);
  const expiresAt = nowMs + days * 86400 * 1000;
  await env.DB.batch([
    // One active connection per account and tool: reconnecting replaces the old one.
    env.DB.prepare("UPDATE mcp_grants SET revoked_at = ?, wrapped_ring = NULL WHERE user_id = ? AND client_id = ? AND revoked_at IS NULL").bind(nowMs, userId, info.clientId),
    env.DB.prepare(
      `INSERT INTO mcp_grants (id, user_id, oauth_grant_id, client_id, client_name, client_domain, redirect_host, scopes, wrapped_ring, created_at, expires_at, last_used_day, revoked_at)
       VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)`,
    ).bind(grantId, userId, info.clientId, info.clientName.slice(0, 200), info.clientDomain ?? null, info.redirectHost.slice(0, 255), scopes.join(" "), wrapped ? wrapped.slice().buffer : null, nowMs, expiresAt),
  ]);
  const props: GrantProps = { userId, grantId, scopes, clientName: info.clientName.slice(0, 200), ...(grantSecret ? { grantSecret } : {}) };
  const { redirectTo } = await helpers.completeAuthorization({ request: approved.request, userId, metadata: { grantId }, scope: scopes, props });
  return json({ redirectTo }, 200, approved.headers);
}

async function deny(request: Request, env: McpEnv): Promise<Response> {
  const b = await body(request);
  if (typeof b.handle !== "string") throw new HttpError(400, "invalid_request", "missing handle");
  const denied = await env.OAUTH_PROVIDER.denyConsent(request, b.handle);
  const h = new Headers(denied.headers);
  h.delete("Location");
  return json({ redirectTo: denied.redirectTo }, 200, h);
}
