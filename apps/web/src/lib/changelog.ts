// Releases from the shared changelog (changelog/*.md, see src/content.config.ts), newest first.
import { getCollection, type CollectionEntry } from "astro:content";

export type Release = CollectionEntry<"releases">;

const parts = (version: string) => version.split(".").map(Number);

export function compareVersions(a: string, b: string): number {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

export async function releases(): Promise<Release[]> {
  const all = await getCollection("releases");
  for (const release of all) {
    if (release.id !== release.data.version) {
      throw new Error(`changelog/${release.id}.md says version ${release.data.version}; the file name must match`);
    }
  }
  return all.sort((a, b) => compareVersions(b.data.version, a.data.version));
}

/** "0.3.3", or "0.1.0 to 0.1.3" for an entry that covers several small releases. */
export const versionLabel = (release: Release) => release.data.covers ?? release.data.version;

/** The anchor of a release on /changelog, e.g. "v0.3.3". */
export const anchor = (release: Release) => `v${release.data.version}`;

const format = (options: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("en-GB", { ...options, timeZone: "UTC" });
export const longDate = (date: Date) => format({ day: "numeric", month: "long", year: "numeric" }).format(date);
export const shortDate = (date: Date) => format({ day: "numeric", month: "short", year: "numeric" }).format(date);
