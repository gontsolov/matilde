import { importJWK, jwtVerify, SignJWT, type JWK } from "jose";
import type { Env } from "../env";
import { UUID_RE } from "../util";

/** Access tokens: 15-minute EdDSA (Ed25519) JWTs, verified statelessly. */
export const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
const ISSUER = "matilde-sync";
const AUDIENCE = "matilde-app";

export interface AccessClaims {
  /** Account id (random UUID). */
  userId: string;
  /** Session id. */
  sessionId: string;
  /** Device id (random per install). */
  deviceId: string;
}

type Key = Awaited<ReturnType<typeof importJWK>>;

interface KeySet {
  source: string;
  signKid: string;
  signKey: Key;
  verify: Map<string, Key>;
}

let cached: Promise<KeySet> | undefined;

async function loadKeys(env: Env): Promise<KeySet> {
  const source = `${env.TOKEN_SIGNING_KEY ?? ""}\n${env.TOKEN_VERIFY_KEYS ?? ""}`;
  if (cached) {
    const set = await cached;
    if (set.source === source) return set;
  }
  cached = (async () => {
    if (!env.TOKEN_SIGNING_KEY) throw new Error("TOKEN_SIGNING_KEY is not set");
    const jwk = JSON.parse(env.TOKEN_SIGNING_KEY) as JWK;
    if (jwk.kty !== "OKP" || jwk.crv !== "Ed25519" || !jwk.d || !jwk.kid) {
      throw new Error("TOKEN_SIGNING_KEY must be an Ed25519 private JWK with a kid");
    }
    const signKey = await importJWK(jwk, "EdDSA");
    const verify = new Map<string, Key>();
    const { d: _d, ...publicJwk } = jwk;
    verify.set(jwk.kid, await importJWK(publicJwk, "EdDSA"));
    if (env.TOKEN_VERIFY_KEYS) {
      for (const old of JSON.parse(env.TOKEN_VERIFY_KEYS) as JWK[]) {
        if (!old.kid || old.d) throw new Error("TOKEN_VERIFY_KEYS entries must be public JWKs with a kid");
        verify.set(old.kid, await importJWK(old, "EdDSA"));
      }
    }
    return { source, signKid: jwk.kid, signKey, verify };
  })();
  try {
    return await cached;
  } catch (error) {
    cached = undefined;
    throw error;
  }
}

export async function signAccessToken(env: Env, claims: AccessClaims, nowMs = Date.now()): Promise<string> {
  const keys = await loadKeys(env);
  const now = Math.floor(nowMs / 1000);
  return new SignJWT({ sid: claims.sessionId, did: claims.deviceId })
    .setProtectedHeader({ alg: "EdDSA", kid: keys.signKid, typ: "at+jwt" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(claims.userId)
    .setIssuedAt(now)
    .setExpirationTime(now + ACCESS_TOKEN_TTL_SECONDS)
    .sign(keys.signKey);
}

/** Returns the claims of a valid, unexpired access token, or null. */
export async function verifyAccessToken(env: Env, token: string): Promise<AccessClaims | null> {
  const keys = await loadKeys(env);
  try {
    const { payload } = await jwtVerify(
      token,
      async (header) => {
        const key = header.kid ? keys.verify.get(header.kid) : undefined;
        if (!key) throw new Error("unknown kid");
        return key;
      },
      { issuer: ISSUER, audience: AUDIENCE, algorithms: ["EdDSA"], typ: "at+jwt" },
    );
    const { sub, sid, did } = payload as { sub?: unknown; sid?: unknown; did?: unknown };
    if (typeof sub !== "string" || typeof sid !== "string" || typeof did !== "string") return null;
    if (!UUID_RE.test(sub) || !UUID_RE.test(sid) || !UUID_RE.test(did)) return null;
    return { userId: sub, sessionId: sid, deviceId: did };
  } catch {
    return null;
  }
}
