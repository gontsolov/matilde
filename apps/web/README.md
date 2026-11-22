# matilde.page

The landing page and privacy page for Matilde. Static [Astro](https://astro.build) site with Tailwind,
served by a small Cloudflare Worker (`matilde-web`) that only redirects `www.matilde.page` to the apex.
It's separate from the sync server in `server/` (`sync.matilde.page`).

## Working on it

Needs Node.js 22.12 or newer and pnpm (`corepack enable` once installs the version pinned in the
root `package.json`). The repo is a pnpm workspace (`apps/web` and `server`) with one root
`pnpm-lock.yaml`; `pnpm install` anywhere in the repo installs both.

```sh
cd apps/web
pnpm install
pnpm run dev        # http://localhost:4321, live reload
pnpm run check      # astro check + worker types
pnpm run build      # static files in dist/
pnpm run preview    # the built site through the Worker (wrangler dev, http://localhost:8787)
```

- Copy lives in `src/pages/index.astro` and `src/pages/privacy.astro`.
- Links and contact address are in `src/lib/site.ts`.
- The page shows no version number, so the build doesn't call GitHub; the button always links to
  the latest release's `Matilde.dmg`. Once the hero button scrolls out of view, a floating copy
  (`src/components/FloatingDownload.astro`) appears at the bottom centre; it hides while the footer is visible.
- Colours are the app's Paper palette, light and dark, in `src/styles/global.css`. The Download
  button is a dark warm gray (`--button`) in light mode and a warm off-white in dark mode.
- Newsreader is self-hosted through Fontsource; small UI text uses the system sans.

### Using a real screenshot

The page shows an interactive HTML/CSS mock-up of the editor (`src/components/EditorMockup.astro`):
a sidebar with four sample notes (a row of tabs below 1024 px), each with Matilde margin comments
that open into a thread. Replies are scripted and cycle in order; nothing is generated or sent.
The notes, comments and replies live in `src/lib/mockup-notes.ts`. Without JavaScript it's a static
view of "Letter to Anna". The red pen underline under “yours” is `src/components/PenMark.astro`. To use a
real screenshot instead, save it as `public/screenshot.png` (about 2400 px wide, light mode).
`src/components/AppPreview.astro` picks it up automatically on the next build. Delete the file to
go back to the mock-up.

## Hosting

The Worker serves `dist/` as static assets. `wrangler.jsonc` attaches it to two custom domains,
`matilde.page` and `www.matilde.page`; on deploy, Cloudflare creates their DNS records and
certificates itself. Neither name has A/AAAA/CNAME records today, so nothing conflicts. The
existing MX, SPF and DMARC records for email stay as they are.

### Deploying by hand

The first deploy ran from GitHub Actions when the site was merged (2026-11-21): it created the
`matilde-web` Worker and both custom domains. Every merge to `main` that touches `apps/web/`
deploys automatically through `.github/workflows/web.yml`. To deploy from the Mac instead (e.g.
Actions unavailable):

```sh
corepack enable && pnpm install
cd apps/web
pnpm exec wrangler login   # the Cloudflare account that owns matilde.page
pnpm run deploy            # builds and runs wrangler deploy
```

### Check it's live

```sh
curl -I https://matilde.page                       # 200
curl -I https://www.matilde.page                   # 301 to https://matilde.page/
curl -sIL https://matilde.page/privacy | head -1   # 200
curl -sI https://github.com/gontsolov/matilde/releases/latest/download/Matilde.dmg | head -1  # 302
```

### GitHub Actions

`.github/workflows/web.yml` uses the repository secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` (the same ones the sync server uses). The token needs:

- Account › Workers Scripts › Edit
- Zone › Workers Routes › Edit, for matilde.page
- Zone › DNS › Edit, for matilde.page (custom domains create DNS records)

The current token already deploys the `sync.matilde.page` custom domain, so it should have these.

- **Pull requests** build and check the site, then upload a preview version of the Worker
  (`wrangler versions upload`) and comment its URL on the PR. This doesn't change matilde.page.
  It's skipped for forks and Dependabot.
- **Main** builds and runs `wrangler deploy`, then checks that matilde.page answers 200 and www
  redirects. There's no approval step: it's a static page with no user data, and a bad deploy is
  undone with `pnpm exec wrangler rollback`.
