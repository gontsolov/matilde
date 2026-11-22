import { describe, expect, it } from "vitest";
import { isBot, parseUpdateCheck } from "../worker/events";
import { APPCAST_URL, DMG_URL, type Env, handle } from "../worker/index";

function fakeEnv() {
  const points: AnalyticsEngineDataPoint[] = [];
  const assets: string[] = [];
  const env: Env = {
    ASSETS: { fetch: async (request: Request) => (assets.push(new URL(request.url).pathname), new Response("page")) } as unknown as Fetcher,
    EVENTS: { writeDataPoint: (point?: AnalyticsEngineDataPoint) => void points.push(point!) },
  };
  return { env, points, assets };
}

const SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15";

describe("/download", () => {
  it("counts one anonymous download and redirects to the latest DMG", async () => {
    const { env, points } = fakeEnv();
    const res = await handle(new Request("https://matilde.page/download", { headers: { "User-Agent": SAFARI, "CF-Connecting-IP": "203.0.113.9" } }), env);
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe(DMG_URL);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(points).toEqual([{ indexes: ["download"], blobs: ["download", "", ""], doubles: [1] }]);
    // Nothing from the request (IP, user agent) is in the data point.
    expect(JSON.stringify(points)).not.toContain("203.0.113.9");
    expect(JSON.stringify(points)).not.toContain("Safari");
  });

  it("doesn't count bots, link previews or HEAD requests", async () => {
    const { env, points } = fakeEnv();
    for (const ua of ["Slackbot-LinkExpanding 1.0", "curl/8.7.1", "Googlebot/2.1", ""]) {
      expect((await handle(new Request("https://matilde.page/download", { headers: { "User-Agent": ua } }), env)).status).toBe(302);
    }
    await handle(new Request("https://matilde.page/download", { method: "HEAD", headers: { "User-Agent": SAFARI } }), env);
    expect(points).toEqual([]);
  });

  it("still redirects when Analytics Engine is missing or fails", async () => {
    const env: Env = { ASSETS: {} as Fetcher };
    expect((await handle(new Request("https://matilde.page/download", { headers: { "User-Agent": SAFARI } }), env)).status).toBe(302);
    const failing: Env = { ASSETS: {} as Fetcher, EVENTS: { writeDataPoint: () => { throw new Error("down"); } } };
    expect((await handle(new Request("https://matilde.page/download", { headers: { "User-Agent": SAFARI } }), failing)).status).toBe(302);
  });
});

describe("/appcast.xml", () => {
  it("counts the update check by app version and macOS major version", async () => {
    const { env, points } = fakeEnv();
    const res = await handle(new Request("https://matilde.page/appcast.xml", { headers: { "User-Agent": "Matilde/0.4.0 Sparkle/2.9.6 macOS/15" } }), env);
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe(APPCAST_URL);
    expect(points).toEqual([{ indexes: ["appcast"], blobs: ["appcast", "0.4.0", "15"], doubles: [1] }]);
  });

  it("keeps only coarse values from the user agent", () => {
    expect(parseUpdateCheck("Matilde/0.3.1 Sparkle/2.9.6")).toEqual({ version: "0.3.1", os: "unknown" });
    expect(parseUpdateCheck("Matilde/0.4.0 Sparkle/2.9.6 macOS/26")).toEqual({ version: "0.4.0", os: "26" });
    expect(parseUpdateCheck("Matilde/0.4.0-evil<script> Sparkle/2.9.6")).toEqual({ version: "other", os: "unknown" });
    expect(parseUpdateCheck("Matilde/99999.1.1 macOS/150")).toEqual({ version: "other", os: "unknown" });
    expect(parseUpdateCheck(SAFARI)).toEqual({ version: "other", os: "unknown" });
    expect(parseUpdateCheck(null)).toEqual({ version: "other", os: "unknown" });
  });
});

describe("everything else", () => {
  it("serves static pages without counting and redirects www", async () => {
    const { env, points, assets } = fakeEnv();
    expect(await (await handle(new Request("https://matilde.page/privacy"), env)).text()).toBe("page");
    expect(assets).toEqual(["/privacy"]);
    const www = await handle(new Request("https://www.matilde.page/download"), env);
    expect(www.status).toBe(301);
    expect(www.headers.get("Location")).toBe("https://matilde.page/download");
    expect(points).toEqual([]);
  });

  it("recognises bots", () => {
    expect(isBot(SAFARI)).toBe(false);
    expect(isBot(null)).toBe(true);
    expect(isBot("Twitterbot/1.0")).toBe(true);
  });
});
