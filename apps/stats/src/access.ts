import { createRemoteJWKSet, type JWTVerifyGetKey, jwtVerify } from "jose";

/**
 * Cloudflare Access puts a signed JWT in `Cf-Access-Jwt-Assertion` on every request it lets
 * through. Checking it here keeps the page closed even if the Access application is missing,
 * misconfigured or bypassed (e.g. a route that Access doesn't cover): the token must be signed
 * by the team's Access keys, carry this application's AUD tag, be unexpired, and belong to an
 * allowed email. Any missing setting means no one gets in.
 */
export interface AccessConfig {
  teamDomain: string;
  aud: string;
  allowedEmails: string[];
}

export type AccessResult = { ok: true; email: string } | { ok: false; reason: string };

export function accessConfig(env: { ACCESS_TEAM_DOMAIN?: string; ACCESS_AUD?: string; ACCESS_ALLOWED_EMAILS?: string }): AccessConfig | null {
  const teamDomain = (env.ACCESS_TEAM_DOMAIN ?? "").trim().replace(/^https?:\/\//, "").replace(/\/+$/, "");
  const aud = (env.ACCESS_AUD ?? "").trim();
  const allowedEmails = (env.ACCESS_ALLOWED_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(teamDomain) || !aud || allowedEmails.length === 0) return null;
  return { teamDomain, aud, allowedEmails };
}

const keySets = new Map<string, JWTVerifyGetKey>();

/** The team's signing keys, fetched from Access and cached by jose. */
export function teamKeys(teamDomain: string): JWTVerifyGetKey {
  let keys = keySets.get(teamDomain);
  if (!keys) {
    keys = createRemoteJWKSet(new URL(`https://${teamDomain}/cdn-cgi/access/certs`));
    keySets.set(teamDomain, keys);
  }
  return keys;
}

export async function verifyAccess(request: Request, config: AccessConfig | null, keys?: JWTVerifyGetKey): Promise<AccessResult> {
  if (!config) return { ok: false, reason: "not_configured" };
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token) return { ok: false, reason: "missing_token" };
  try {
    const { payload } = await jwtVerify(token, keys ?? teamKeys(config.teamDomain), {
      issuer: `https://${config.teamDomain}`,
      audience: config.aud,
      algorithms: ["RS256"],
    });
    const email = typeof payload.email === "string" ? payload.email.toLowerCase() : "";
    if (!email || !config.allowedEmails.includes(email)) return { ok: false, reason: "not_allowed" };
    return { ok: true, email };
  } catch {
    return { ok: false, reason: "invalid_token" };
  }
}
