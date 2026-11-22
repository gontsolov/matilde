# stats.matilde.page

The owner's private dashboard of anonymous usage counts: a Cloudflare Worker (`matilde-stats`)
behind Cloudflare Access that also verifies the Access JWT itself. What each number means, its
limits, and the owner's setup steps are in [docs/stats.md](../../docs/stats.md).

```sh
cd apps/stats
pnpm install
pnpm run check      # tsc + vitest (Access JWT check, data sources, page)
```

`src/index.ts` checks access and renders the page; `src/access.ts` is the JWT check;
`src/sources.ts` reads Analytics Engine, Web Analytics, GitHub and the sync server's `StatsApi`
(service binding `SYNC`); `src/page.ts` is the HTML. Deployed by `.github/workflows/stats.yml` on
merge to `main`.
