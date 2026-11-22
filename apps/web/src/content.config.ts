// The user-facing changelog: one Markdown file per release in changelog/ at the repo root, shared
// with the Mac and iPhone apps (see changelog/README.md for the format). Read at build time.
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

const releases = defineCollection({
  loader: glob({
    pattern: "[0-9]*.md",
    base: "../../changelog",
    generateId: ({ entry }) => entry.replace(/\.md$/, ""),
  }),
  schema: z.object({
    version: z.string().regex(/^\d+\.\d+\.\d+$/),
    /** Earlier releases folded into this entry, e.g. "0.1.0 to 0.1.3". */
    covers: z.string().optional(),
    date: z.coerce.date(),
    title: z.string(),
    /** Matilde's one-liner for the margin card. */
    matilde: z.string().optional(),
  }),
});

export const collections = { releases };
