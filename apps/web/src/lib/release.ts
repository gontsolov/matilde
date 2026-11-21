import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { REPO } from "./site";

/** The version shown next to the download button: the latest GitHub release at build time. */
export interface Release {
  version: string | null;
  /** True only when the GitHub API confirmed the latest release has a Matilde.dmg asset. */
  confirmed: boolean;
}

let cached: Promise<Release> | undefined;

export function latestRelease(): Promise<Release> {
  cached ??= load();
  return cached;
}

async function load(): Promise<Release> {
  try {
    const headers: Record<string, string> = { Accept: "application/vnd.github+json", "User-Agent": "matilde-web-build" };
    if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
    const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers,
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) throw new Error(`GitHub API ${response.status}`);
    const data = (await response.json()) as { tag_name?: string; assets?: { name: string }[] };
    const version = data.tag_name?.replace(/^v/, "") ?? null;
    const hasDmg = data.assets?.some((asset) => asset.name === "Matilde.dmg") ?? false;
    if (!hasDmg) console.warn("[release] latest release has no Matilde.dmg asset");
    return { version, confirmed: hasDmg };
  } catch (error) {
    // Offline or rate-limited: fall back to the app's configured version, or show none.
    console.warn(`[release] ${(error as Error).message}; using the fallback version`);
    return { version: fallbackVersion(), confirmed: false };
  }
}

function fallbackVersion(): string | null {
  try {
    const config = JSON.parse(readFileSync(resolve(process.cwd(), "../macos/Config/release.json"), "utf8"));
    return typeof config.version === "string" ? config.version : null;
  } catch {
    return null;
  }
}
