# Changelog

What's new in each Matilde release, written for the people who use it. One file per release, named
after its version (`0.3.3.md`). These files are the single source for:

- **matilde.page/changelog** (`apps/web`, an Astro content collection),
- the **What's New** window in the Mac app (bundled into the app, shown once after an update and from
  Help → What's New in Matilde…),
- **What's New** in the iPhone app's Settings (bundled too),
- the **update dialog** Sparkle shows (embedded in the signed appcast), and
- the **GitHub release** body.

A release fails before it builds when its file is missing or breaks the rules below:

```sh
python3 apps/macos/scripts/changelog.py check          # every entry
python3 apps/macos/scripts/changelog.py check 0.3.4    # and require this one
```

## Format

```markdown
---
version: 0.3.4
date: 2026-11-30
title: A short, friendly headline
matilde: An optional one-liner from Matilde, shown in the margin.
---

One or two warm sentences about what this release means for the person writing.

- One bullet per change, in plain words. **Bold** and [links](https://matilde.page) are fine.
- Lead with what they can now do, not how it was built.
```

- Front matter is plain `key: value` lines. Keep values plain text: no quotes and no `: ` inside a value.
- `version` (required) must match the file name. `date` (required) is `YYYY-MM-DD`. `title` (required).
- `covers` (optional) groups several small releases into one entry, for example `covers: 0.1.4 to 0.1.7`
  in `0.1.7.md`. The older versions in the range don't get their own files.
- `matilde` (optional) is a margin note in Matilde's voice.
- The body is short paragraphs and `- ` bullets, nothing else (no headings, images or code).

## Voice

- Talk to the person: "you can now…", "your notes…". Never company voice ("by us", "we can't read",
  "not even us"); privacy copy centres on the person (their notes are encrypted, no one else can read them).
- Spell the name **Matilde**; the writing assistant is **Ask Matilde**. Don't name the developer.
- No pull request numbers, file names, code formatting or internal IDs. Keep fixes human: "Comments no
  longer jump when you scroll", not "Fixed offset bug in ThreadLayout".
- A release with only small fixes can say so in one or two bullets.

The check enforces the mechanical parts of these rules; the rest is up to whoever writes the entry.
