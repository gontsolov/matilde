# matilde.page

The landing page and privacy page for Matilde. Static [Astro](https://astro.build) site with Tailwind,
served by a small Cloudflare Worker (`matilde-web`) that only redirects `www.matilde.page` to the apex.
It's separate from the sync server in `server/` (`sync.matilde.page`).

## Working on it

```sh
cd apps/web
npm ci
npm run dev        # http://localhost:4321, live reload
npm run check      # astro check + worker types
npm run build      # static files in dist/
npm run preview    # the built site through the Worker (wrangler dev, http://localhost:8787)
```

- Copy lives in `src/pages/index.astro` and `src/pages/privacy.astro`.
- Links, platform line and contact address are in `src/lib/site.ts`.
- The version shown next to the button comes from the latest GitHub release at build time
  (only if it has a `Matilde.dmg` asset), falling back to `apps/macos/Config/release.json`.
- Colours are the app's Paper palette, light and dark, in `src/styles/global.css`.
- Newsreader is self-hosted through Fontsource; small UI text uses the system sans.

### Using a real screenshot

The page shows an HTML/CSS mock-up of the editor (`src/components/EditorMockup.astro`). To use a
real screenshot instead, save it as `public/screenshot.png` (about 2400 px wide, light mode).
`src/components/AppPreview.astro` picks it up automatically on the next build. Delete the file to
go back to the mock-up.

## Hosting

The Worker serves `dist/` as static assets. `wrangler.jsonc` attaches it to two custom domains,
`matilde.page` and `www.matilde.page`; on deploy, Cloudflare creates their DNS records and
certificates itself. Neither name has A/AAAA/CNAME records today, so nothing conflicts. The
existing MX, SPF and DMARC records for email stay as they are.

### First deploy (once, from the Mac)

```sh
cd apps/web
npm ci
npx wrangler login      # the Cloudflare account that owns matilde.page
npm run deploy          # builds and runs wrangler deploy
```

After that, every merge to `main` that touches `apps/web/` deploys automatically through
`.github/workflows/web.yml`.

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
  It's skipped for forks and Dependabot, and it fails harmlessly until the first deploy has
  created the `matilde-web` Worker.
- **Main** builds and runs `wrangler deploy`, then checks that matilde.page answers 200 and www
  redirects. There's no approval step: it's a static page with no user data, and a bad deploy is
  undone with `npx wrangler rollback`.
