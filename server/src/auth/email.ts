import type { Env } from "../env";
import { HttpError, hmacHex, randomBytes, timingSafeEqual } from "../util";
import { findOrCreateAccount } from "./accounts";
import { createMailer, signInMail } from "./mailer";
import { enforceLimits, ipPrefix } from "./ratelimit";
import { createSession, type NewSession, type TokenPair } from "./sessions";

export const CODE_TTL_MS = 10 * 60 * 1000;
export const CODE_MAX_ATTEMPTS = 5;

export const EMAIL_LIMITS = {
  perEmail15Min: 3,
  perEmailDay: 10,
  perIpHour: 20,
  verifyPerIpHour: 60,
} as const;

const EMAIL_RE = /^[^\s@<>()",;:\\[\]]+@[^\s@<>()",;:\\[\]]+\.[^\s@<>()",;:\\[\]]+$/;

export function normalizeEmail(raw: unknown): string {
  if (typeof raw !== "string") throw new HttpError(400, "invalid_email");
  const email = raw.trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) throw new HttpError(400, "invalid_email");
  return email;
}

/** Uniform 6-digit code (rejection sampling, no modulo bias). */
export function generateCode(): string {
  for (;;) {
    const bytes = randomBytes(4);
    const value = ((bytes[0]! << 24) | (bytes[1]! << 16) | (bytes[2]! << 8) | bytes[3]!) >>> 0;
    if (value < 4_294_000_000) return String(value % 1_000_000).padStart(6, "0");
  }
}

const emailKey = (env: Env, email: string) => hmacHex(env.CODE_PEPPER, `email:${email}`);
const codeHash = (env: Env, email: string, code: string) => hmacHex(env.CODE_PEPPER, `code:${email}:${code}`);
const ipKey = (env: Env, ip: string) => hmacHex(env.CODE_PEPPER, `ip:${ipPrefix(ip)}`);

/** Sends a new code, replacing any active one. Same response whether or not the address has an account. */
export async function startEmailSignIn(env: Env, rawEmail: unknown, ip: string, nowMs = Date.now()): Promise<void> {
  if (!env.CODE_PEPPER) throw new Error("CODE_PEPPER is not set");
  const email = normalizeEmail(rawEmail);
  const key = await emailKey(env, email);
  const network = await ipKey(env, ip);
  try {
    await enforceLimits(
      env.DB,
      [
        { key: "code:global:day", windowSeconds: 86400, max: Number(env.GLOBAL_DAILY_CODE_CAP || 2000) },
        { key: `code:ip:${network}`, windowSeconds: 3600, max: EMAIL_LIMITS.perIpHour },
        { key: `code:email15:${key}`, windowSeconds: 900, max: EMAIL_LIMITS.perEmail15Min },
        { key: `code:emailday:${key}`, windowSeconds: 86400, max: EMAIL_LIMITS.perEmailDay },
      ],
      nowMs,
    );
  } catch (error) {
    if (error instanceof HttpError && error.code === "rate_limited") {
      console.warn(JSON.stringify({ event: "sign_in_code_rate_limited" }));
    }
    throw error;
  }
  const code = generateCode();
  await env.DB.prepare(
    `INSERT INTO email_codes (email_key, code_hash, expires_at, attempts, created_at) VALUES (?, ?, ?, 0, ?)
     ON CONFLICT(email_key) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0, created_at = excluded.created_at`,
  )
    .bind(key, await codeHash(env, email, code), nowMs + CODE_TTL_MS, nowMs)
    .run();
  try {
    await createMailer(env).send(signInMail(email, code));
  } catch (error) {
    await env.DB.prepare("DELETE FROM email_codes WHERE email_key = ?").bind(key).run();
    console.error(JSON.stringify({ event: "mail_failed", message: error instanceof Error ? error.message : "unknown" }));
    throw new HttpError(502, "mail_failed", "could not send the code, try again later");
  }
}

export interface VerifyInput extends Omit<NewSession, "userId"> {
  email: unknown;
  code: unknown;
}

const invalidCode = () => new HttpError(400, "invalid_code", "the code is wrong or has expired");

/** Checks a code (at most 5 attempts, then it is burned) and signs the device in. */
export async function verifyEmailCode(env: Env, input: VerifyInput, ip: string, nowMs = Date.now()): Promise<TokenPair & { isNewAccount: boolean }> {
  const email = normalizeEmail(input.email);
  if (typeof input.code !== "string" || !/^\d{6}$/.test(input.code)) throw invalidCode();
  await enforceLimits(env.DB, [{ key: `verify:ip:${await ipKey(env, ip)}`, windowSeconds: 3600, max: EMAIL_LIMITS.verifyPerIpHour }], nowMs);
  const key = await emailKey(env, email);

  // Spend an attempt before comparing, atomically, so parallel guesses can't exceed the limit.
  const reserved = await env.DB.prepare(
    `UPDATE email_codes SET attempts = attempts + 1
     WHERE email_key = ? AND attempts < ? AND expires_at > ?
     RETURNING code_hash, attempts`,
  )
    .bind(key, CODE_MAX_ATTEMPTS, nowMs)
    .first<{ code_hash: string; attempts: number }>();
  if (!reserved) {
    await env.DB.prepare("DELETE FROM email_codes WHERE email_key = ?").bind(key).run();
    throw invalidCode();
  }
  const presented = await codeHash(env, email, input.code);
  if (!timingSafeEqual(presented, reserved.code_hash)) {
    if (reserved.attempts >= CODE_MAX_ATTEMPTS) {
      await env.DB.prepare("DELETE FROM email_codes WHERE email_key = ?").bind(key).run();
    }
    throw invalidCode();
  }
  const consumed = await env.DB.prepare("DELETE FROM email_codes WHERE email_key = ? AND code_hash = ? RETURNING email_key")
    .bind(key, reserved.code_hash)
    .first();
  if (!consumed) throw invalidCode();

  const account = await findOrCreateAccount(env, { provider: "email", subject: email, email }, nowMs);
  const tokens = await createSession(
    env,
    { userId: account.userId, deviceId: input.deviceId, platform: input.platform, nameCt: input.nameCt },
    nowMs,
  );
  return { ...tokens, isNewAccount: account.created };
}
