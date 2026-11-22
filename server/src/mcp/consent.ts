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
import { BIP39_WORDS, CONNECT_JS, ICON_PNG_BASE64, NEWSREADER_WOFF2_BASE64 } from "./web/assets.generated";

export type McpEnv = Env & { OAUTH_KV: KVNamespace; OAUTH_PROVIDER: OAuthHelpers };

const SCOPE_TEXT: Record<string, { label: string; detail: string }> = {
  "notes:read": { label: "Read your notes", detail: "List, search and read notes and their comments." },
  "notes:comment": { label: "Comment on your notes", detail: "Add comments to a passage. The note itself stays as it is." },
  "notes:create": { label: "Create notes", detail: "Add new notes. Existing notes aren't changed." },
  "notes:edit": { label: "Edit your notes", detail: "Change the text of existing notes. Off unless you turn it on." },
  feedback: { label: "Send feedback about Matilde", detail: "Pass on a bug report or idea when you ask it to. Needs no access to notes." },
};

const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

// Matilde's look: the app's Paper palette and the Newsreader serif, as on matilde.page
// (apps/web/src/styles/global.css). Light and dark follow the system.
const CSS = `@font-face{font-family:"Newsreader";font-style:normal;font-weight:200 800;font-display:swap;src:url(/connect/newsreader.woff2) format("woff2-variations")}
:root{color-scheme:light dark;--paper:#f9f6ef;--sidebar:#f4f2ee;--ink:#3d4038;--muted:#7a7a6e;--accent:#7a523b;--card:#fffdf8;--rule:rgb(61 64 56/.1);--field:#f4f2ee;--button:#2b2724;--button-hover:#3a3531;--button-ink:#f6f2ea;--pen:#b9432c;--warn:#8a5a16;--shadow:0 1px 2px rgb(0 0 0/.04),0 10px 30px -18px rgb(0 0 0/.18)}
@media (prefers-color-scheme:dark){:root{--paper:#212222;--sidebar:#1b1b1c;--ink:#dedddb;--muted:#9e9fa1;--accent:#b0a699;--card:#262727;--rule:rgb(222 221 219/.1);--field:#1b1b1c;--button:#ebe5da;--button-hover:#f6f2ea;--button-ink:#2b2724;--pen:#d9705a;--warn:#d9a55a;--shadow:none}}
*{box-sizing:border-box}
html{background:var(--paper);color:var(--ink);-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
body{margin:0;font:15px/1.5 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;min-height:100vh;min-height:100dvh;display:flex;justify-content:center;align-items:flex-start}
main{width:100%;max-width:26.5rem;padding:3.5rem 1.25rem 3rem}
@media (min-height:760px){main{padding-top:5.5rem}}
.brand{display:flex;align-items:center;justify-content:center;gap:.55rem;color:var(--muted);font-size:14px;font-weight:500;letter-spacing:-.005em;margin-bottom:1.75rem}
.brand img{width:32px;height:32px;border-radius:8px}
h1,h2{font-family:"Newsreader","Iowan Old Style",Georgia,serif;font-weight:500;letter-spacing:-.012em;color:var(--ink);margin:0}
h1{font-size:30px;line-height:1.15;text-align:center}
h2{font-size:21px;line-height:1.25;margin-bottom:.35rem}
p{margin:0}
.lede{text-align:center;color:var(--muted);font-size:14px;margin-top:.6rem}
.lede strong{color:var(--ink);font-weight:500}
.lede+.lede{margin-top:.25rem}
.warn{color:var(--warn)}
section{background:var(--card);border:1px solid var(--rule);border-radius:16px;padding:1.35rem 1.35rem 1.25rem;margin-top:1.6rem;box-shadow:var(--shadow)}
section[hidden]{display:none}
.hint{color:var(--muted);font-size:14px}
.scopes{margin:.85rem 0 0;padding:0;border:0}
.scope{display:flex;gap:.85rem;align-items:flex-start;padding:.7rem 0;border-top:1px solid var(--rule);cursor:pointer}
.scope:first-of-type{border-top:0;padding-top:.2rem}
.scope-text{display:flex;flex-direction:column;gap:.1rem;flex:1;min-width:0}
.scope-title{font-size:15px;font-weight:500;line-height:1.35}
.scope-detail{font-size:13px;line-height:1.4;color:var(--muted)}
.scope input{appearance:none;-webkit-appearance:none;flex:none;margin:.1rem 0 0;width:34px;height:20px;border-radius:999px;background:var(--rule);border:1px solid var(--rule);position:relative;cursor:pointer;transition:background .15s ease}
.scope input::after{content:"";position:absolute;top:1px;left:1px;width:16px;height:16px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgb(0 0 0/.25);transition:transform .15s ease}
.scope input:checked{background:var(--button);border-color:var(--button)}
.scope input:checked::after{transform:translateX(14px);background:var(--button-ink)}
@media (prefers-color-scheme:dark){.scope input{background:rgb(222 221 219/.16)}.scope input::after{background:#dedddb}}
.scope input:focus-visible,.segments input:focus-visible+span,.otp input:focus-visible~.otp-boxes .active{outline:2px solid var(--accent);outline-offset:2px}
.field-label{display:block;font-size:13px;font-weight:500;color:var(--muted);margin:1.1rem 0 .45rem}
.segments{display:grid;grid-template-columns:repeat(4,1fr);gap:3px;padding:3px;border-radius:10px;background:var(--field);border:1px solid var(--rule);margin:0}
.segments label{position:relative;cursor:pointer}
.segments input{position:absolute;opacity:0;inset:0;margin:0;cursor:pointer}
.segments span{display:block;text-align:center;font-size:13px;font-weight:500;padding:.35rem 0;border-radius:7px;color:var(--muted);transition:background .15s ease,color .15s ease}
.segments input:checked+span{background:var(--card);color:var(--ink);box-shadow:0 1px 2px rgb(0 0 0/.08)}
@media (prefers-color-scheme:dark){.segments input:checked+span{background:#333434}}
.note{margin-top:1.1rem;font-size:13px;line-height:1.5;color:var(--muted)}
.note strong{color:var(--ink);font-weight:500}
input[type=email],textarea{display:block;width:100%;font:inherit;font-size:16px;padding:.6rem .8rem;margin-top:.85rem;border:1px solid var(--rule);border-radius:10px;background:var(--field);color:var(--ink);outline:none;transition:border-color .15s ease}
input[type=email]:focus,textarea:focus{border-color:var(--accent)}
textarea{min-height:6.2rem;resize:vertical;line-height:1.45}
.otp{position:relative;margin-top:.95rem}
.otp input{position:absolute;inset:0;width:100%;height:100%;opacity:0;font-size:16px;border:0;padding:0;margin:0;background:transparent;color:transparent;caret-color:transparent}
.otp-boxes{display:grid;grid-template-columns:repeat(6,1fr);gap:8px;pointer-events:none}
.otp-boxes span{height:54px;display:flex;align-items:center;justify-content:center;border-radius:12px;background:var(--field);border:1px solid rgb(122 122 110/.28);font:500 26px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ink);transition:border-color .15s ease}
.otp.focused .otp-boxes span.active{border:2px solid var(--accent)}
.otp.shake{animation:shake .4s linear}
@keyframes shake{20%,60%{transform:translateX(-5px)}40%,80%{transform:translateX(5px)}}
@media (prefers-reduced-motion:reduce){.otp.shake{animation:none}*{transition:none!important}}
.row{display:flex;flex-wrap:wrap;align-items:center;gap:.4rem;margin-top:1.25rem}
button{font:inherit;cursor:pointer}
.primary{display:inline-flex;align-items:center;gap:.4rem;border:0;border-radius:999px;background:var(--button);color:var(--button-ink);padding:.5rem 1.05rem;font-size:14px;font-weight:500;letter-spacing:-.005em;transition:background .15s ease}
.primary:hover{background:var(--button-hover)}
.quiet{border:0;background:none;color:var(--muted);padding:.5rem .7rem;font-size:14px;font-weight:500;border-radius:999px}
.quiet:hover{color:var(--ink);background:var(--rule)}
button:disabled{opacity:.45;cursor:default}
button[aria-busy=true]{opacity:.7;cursor:progress}
button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.error{color:var(--pen);font-size:13.5px;margin-top:.7rem}
.error[hidden]{display:none}
.done{text-align:center;padding:1.75rem 1.35rem}
.check{width:40px;height:40px;margin:0 auto .8rem;border-radius:50%;background:var(--button);position:relative}
.check::after{content:"";position:absolute;left:14px;top:10px;width:9px;height:16px;border:solid var(--button-ink);border-width:0 2px 2px 0;transform:rotate(45deg)}
code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--field);border:1px solid var(--rule);border-radius:6px;padding:.1rem .35rem;color:var(--ink)}
.center{text-align:center}
section>p+p{margin-top:.5rem}
.footer{margin-top:1.4rem;text-align:center;font-size:12.5px;color:var(--muted)}
.footer a{color:inherit}
@media (max-width:420px){main{padding-top:2.25rem}h1{font-size:26px}section{padding:1.15rem 1.1rem 1.1rem;border-radius:14px}.otp-boxes{gap:6px}.otp-boxes span{height:48px;font-size:23px}}`;

const escape = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);

const BRAND = `<div class="brand"><img src="/connect/icon.png" alt="" width="32" height="32"><span>Matilde</span></div>`;

function page(title: string, body: string, headers?: Headers, status = 200): Response {
  const h = new Headers(headers);
  h.set("Content-Type", "text/html; charset=utf-8");
  h.set("Content-Security-Policy", CSP);
  h.set("Cache-Control", "no-store");
  h.set("Referrer-Policy", "no-referrer");
  h.set("X-Content-Type-Options", "nosniff");
  h.set("X-Frame-Options", "DENY");
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>${escape(title)}</title><link rel="icon" href="/connect/icon.png"><link rel="preload" href="/connect/newsreader.woff2" as="font" type="font/woff2" crossorigin><link rel="stylesheet" href="/connect/app.css"></head><body><main>${BRAND}${body}</main></body></html>`;
  return new Response(html, { status, headers: h });
}

function errorPage(detail: string, status = 400): Response {
  return page(
    "Matilde",
    `<h1>Couldn't connect</h1><section><p>The request from your AI tool can't be used. Start connecting again from the tool.</p><p class="hint">Details: ${escape(detail)}</p></section>`,
    undefined,
    status,
  );
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
    ? `<p class="lede">Verified domain: <strong>${escape(info.clientDomain)}</strong></p>`
    : `<p class="lede">“${name}” is the name the tool gave itself and isn't verified. Continue only if you started this from that tool.</p>`;
  const loopback = info.redirectIsLoopback
    ? `<p class="lede warn">This connection goes to an app on this computer. Any program running here could receive it, whatever name it gives.</p>`
    : "";
  const scopes = SCOPES.map((s) => {
    const t = SCOPE_TEXT[s]!;
    const checked = (DEFAULT_SCOPES as readonly string[]).includes(s) ? " checked" : "";
    return `<label class="scope"><span class="scope-text"><span class="scope-title">${escape(t.label)}</span><span class="scope-detail">${escape(t.detail)}</span></span><input type="checkbox" role="switch" name="scope" value="${s}"${checked}></label>`;
  }).join("");
  const days = DURATIONS_DAYS.map(
    (d) => `<label><input type="radio" name="days" value="${d}"${d === DEFAULT_DURATION_DAYS ? " checked" : ""}><span>${d === 1 ? "1 day" : `${d} days`}</span></label>`,
  ).join("");
  const deny = `<button class="quiet" type="button" data-deny>Don't connect</button>`;
  const body = `<div id="connect" data-handle="${escape(handle)}">
<h1>Connect ${name}</h1>
<p class="lede">${name} would like to work with your Matilde notes. Afterwards you'll go back to <strong>${escape(info.redirectHost)}</strong>.</p>${verified}${loopback}
<section data-step="scopes"><form id="form-scopes">
<h2>What may ${name} do?</h2>
<fieldset class="scopes" aria-label="Permissions">${scopes}</fieldset>
<span class="field-label" id="days-label">Connection ends after</span>
<fieldset class="segments" aria-labelledby="days-label">${days}</fieldset>
<p class="note">While connected, the Matilde server can decrypt your notes so ${name} can work with them, and ${name} sees what it reads. <strong>Your Matilde key stays in this browser.</strong> End the connection any time in Matilde's Settings, under Connected AI tools.</p>
<p class="error" id="scopes-error" role="alert" hidden></p>
<div class="row"><button class="primary" id="scopes-continue" type="submit">Continue</button>${deny}</div></form></section>
<section data-step="email" hidden><form id="form-email">
<h2>Confirm it's you</h2>
<p class="hint"><label for="email">Enter the email address you use for Matilde sync. A sign-in code will arrive there.</label></p>
<input id="email" type="email" autocomplete="email" placeholder="you@example.com" required>
<p class="error" id="email-error" role="alert" hidden></p>
<div class="row"><button class="primary" id="email-continue" type="submit">Send code</button>${deny}</div></form></section>
<section data-step="code" hidden><form id="form-code">
<h2>Check your email</h2>
<p class="hint"><label for="code">Enter the 6-digit code sent to <strong id="code-email"></strong>.</label></p>
<div class="otp" id="otp"><input id="code" type="text" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]*" required><div class="otp-boxes" aria-hidden="true"><span></span><span></span><span></span><span></span><span></span><span></span></div></div>
<p class="error" id="code-error" role="alert" hidden></p>
<div class="row"><button class="primary" id="code-continue" type="submit">Continue</button><button class="quiet" type="button" id="code-back">Change email</button></div></form></section>
<section data-step="key" hidden><form id="form-key">
<h2>Enter your Matilde key</h2>
<p class="hint"><label for="key">The 12 words (or the code starting with MTLD) you saved when you turned on sync. It's checked here in your browser and never sent anywhere.</label></p>
<textarea id="key" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="word word word …" required></textarea>
<p class="error" id="key-error" role="alert" hidden></p>
<div class="row"><button class="primary" id="key-continue" type="submit">Connect</button>${deny}</div></form></section>
<section data-step="done" class="done" hidden><div class="check" aria-hidden="true"></div><h2>Connected</h2><p class="hint">Taking you back to ${name}…</p></section>
<noscript><section><p class="error">Connecting needs JavaScript: your key is checked in this browser.</p></section></noscript>
</div><script type="module" src="/connect/app.js"></script>`;
  return page(`Connect ${info.clientName} to Matilde`, body, headers);
}

const ICON_PNG = base64ToBytes(ICON_PNG_BASE64)!;
const NEWSREADER_WOFF2 = base64ToBytes(NEWSREADER_WOFF2_BASE64)!;

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
          return page(
            "Matilde for AI tools",
            `<h1>Matilde for AI tools</h1><p class="lede">Let an AI tool you choose read and add to your Matilde notes.</p><section><p>Add this address to your AI tool as a custom connector (MCP server):</p><p><code>${escape(url.origin)}/mcp</code></p><p class="hint">The tool sends you to a Matilde page to sign in and choose what it may do. You can end the connection any time in Matilde's Settings.</p></section><p class="footer"><a href="https://matilde.page/privacy#ai-tools">How privacy works</a></p>`,
          );
        case "/authorize":
          return await authorize(request, env);
        case "/connect/app.js":
          return new Response(CONNECT_JS, { headers: { ...ASSET_HEADERS, "Content-Type": "text/javascript; charset=utf-8" } });
        case "/connect/app.css":
          return new Response(CSS, { headers: { ...ASSET_HEADERS, "Content-Type": "text/css; charset=utf-8" } });
        case "/connect/icon.png":
          return new Response(ICON_PNG, { headers: { ...ASSET_HEADERS, "Content-Type": "image/png" } });
        case "/connect/newsreader.woff2":
          return new Response(NEWSREADER_WOFF2, { headers: { ...ASSET_HEADERS, "Content-Type": "font/woff2" } });
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
