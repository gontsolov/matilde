import { createLocalJWKSet, exportJWK, generateKeyPair, type JWK, SignJWT } from "jose";
import { beforeAll, describe, expect, it } from "vitest";
import { accessConfig, type AccessConfig, verifyAccess } from "../src/access";
import type { Env } from "../src/env";
import { handle } from "../src/index";

const TEAM = "matilde.cloudflareaccess.com";
const AUD = "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2";
const OWNER = "owner@example.com";
const config: AccessConfig = { teamDomain: TEAM, aud: AUD, allowedEmails: [OWNER] };

let teamKey: CryptoKey;
let otherKey: CryptoKey;
let keys: ReturnType<typeof createLocalJWKSet>;

beforeAll(async () => {
  const team = await generateKeyPair("RS256");
  const other = await generateKeyPair("RS256");
  teamKey = team.privateKey;
  otherKey = other.privateKey;
  const jwk: JWK = { ...(await exportJWK(team.publicKey)), kid: "team-1", alg: "RS256" };
  keys = createLocalJWKSet({ keys: [jwk] });
});

function token(overrides: { key?: CryptoKey; iss?: string; aud?: string; email?: string | null; exp?: string | number } = {}) {
  const jwt = new SignJWT(overrides.email === null ? {} : { email: overrides.email ?? OWNER })
    .setProtectedHeader({ alg: "RS256", kid: "team-1" })
    .setIssuer(overrides.iss ?? `https://${TEAM}`)
    .setAudience(overrides.aud ?? AUD)
    .setSubject("access-user")
    .setIssuedAt()
    .setExpirationTime(overrides.exp ?? "1h");
  return jwt.sign(overrides.key ?? teamKey);
}

function request(jwt?: string) {
  return new Request("https://stats.matilde.page/", { headers: jwt ? { "Cf-Access-Jwt-Assertion": jwt } : {} });
}

describe("Access JWT check", () => {
  it("lets the owner in with a valid token", async () => {
    expect(await verifyAccess(request(await token()), config, keys)).toEqual({ ok: true, email: OWNER });
    expect(await verifyAccess(request(await token({ email: "Owner@Example.com" })), config, keys)).toEqual({ ok: true, email: OWNER });
  });

  it("refuses a missing, forged, expired or foreign token", async () => {
    const cases: [string | undefined, string][] = [
      [undefined, "missing_token"],
      ["not.a.jwt", "invalid_token"],
      [await token({ key: otherKey }), "invalid_token"],
      [await token({ exp: Math.floor(Date.now() / 1000) - 60 }), "invalid_token"],
      [await token({ aud: "another-application" }), "invalid_token"],
      [await token({ iss: "https://evil.cloudflareaccess.com" }), "invalid_token"],
      [await token({ email: "someone@example.com" }), "not_allowed"],
      [await token({ email: null }), "not_allowed"],
    ];
    for (const [jwt, reason] of cases) {
      expect(await verifyAccess(request(jwt), config, keys)).toEqual({ ok: false, reason });
    }
  });

  it("refuses an unsigned ('none') token", async () => {
    const unsigned = `${btoa(JSON.stringify({ alg: "none", typ: "JWT" }))}.${btoa(JSON.stringify({ email: OWNER, aud: AUD, iss: `https://${TEAM}` }))}.`;
    expect(await verifyAccess(request(unsigned), config, keys)).toEqual({ ok: false, reason: "invalid_token" });
  });

  it("stays closed when the Access settings are missing", async () => {
    expect(accessConfig({})).toBeNull();
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD })).toBeNull();
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: "", ACCESS_AUD: AUD, ACCESS_ALLOWED_EMAILS: OWNER })).toBeNull();
    expect(await verifyAccess(request(await token()), null, keys)).toEqual({ ok: false, reason: "not_configured" });
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: `https://${TEAM}/`, ACCESS_AUD: ` ${AUD} `, ACCESS_ALLOWED_EMAILS: ` ${OWNER.toUpperCase()}, b@example.com ` })).toEqual({
      teamDomain: TEAM,
      aud: AUD,
      allowedEmails: [OWNER, "b@example.com"],
    });
  });
});

describe("the Worker", () => {
  const env: Env = { GITHUB_REPO: "gontsolov/matilde", EVENTS_DATASET: "matilde_web_events", ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD, ACCESS_ALLOWED_EMAILS: OWNER };
  const failingFetch = (async () => {
    throw new Error("no network in tests");
  }) as unknown as typeof fetch;

  it("answers 403 without loading any data when the token is missing or wrong", async () => {
    let loaded = false;
    const spy = (async () => ((loaded = true), new Response("{}"))) as unknown as typeof fetch;
    const verify = (req: Request, cfg: AccessConfig | null) => verifyAccess(req, cfg, keys);
    for (const req of [request(), request(await token({ email: "someone@example.com" }))]) {
      const res = await handle(req, { ...env, SYNC: { stats: async () => ((loaded = true), {} as never) } }, { verify, fetcher: spy });
      expect(res.status).toBe(403);
      expect(res.headers.get("Cache-Control")).toBe("private, no-store");
    }
    expect(loaded).toBe(false);
    // Missing configuration: closed even with a valid token.
    const res = await handle(request(await token()), { GITHUB_REPO: env.GITHUB_REPO, EVENTS_DATASET: env.EVENTS_DATASET }, { verify, fetcher: spy });
    expect(res.status).toBe(403);
  });

  it("renders the page for the owner even when every source is down", async () => {
    const verify = (req: Request, cfg: AccessConfig | null) => verifyAccess(req, cfg, keys);
    const res = await handle(request(await token()), env, { verify, fetcher: failingFetch });
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toContain("text/html");
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex, nofollow");
    const html = await res.text();
    expect(html).toContain("Matilde in numbers");
    expect(html).toContain("Not available");
  });
});
