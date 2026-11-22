// Renders the link-preview images (Open Graph / Twitter cards) into public/:
//   og-image.png          home page: icon, headline and a slice of the editor
//   og-image-privacy.png  privacy page
// 1200×630, the size link previews expect. Only Newsreader (from @fontsource-variable, the same
// files the site serves) and the app icon are used, so the output doesn't depend on system fonts.
//
//   cd apps/web
//   pnpm exec playwright install chromium   # once
//   pnpm run og-image
//
// Commit the PNGs; the build doesn't render them.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dataUrl = (path, type) => `data:${type};base64,${readFileSync(path).toString("base64")}`;
const fonts = resolve(root, "node_modules/@fontsource-variable/newsreader/files");
const roman = dataUrl(resolve(fonts, "newsreader-latin-opsz-normal.woff2"), "font/woff2");
const italic = dataUrl(resolve(fonts, "newsreader-latin-opsz-italic.woff2"), "font/woff2");
// The 1254 px app icon, so it stays sharp at any scale.
const icon = dataUrl(resolve(root, "../macos/assets/AppIcon.png"), "image/png");

// Paper palette, light (src/styles/global.css).
const css = `
@font-face { font-family: "Newsreader"; src: url(${roman}) format("woff2"); font-weight: 200 800; font-style: normal; }
@font-face { font-family: "Newsreader"; src: url(${italic}) format("woff2"); font-weight: 200 800; font-style: italic; }
:root { --paper: #f9f6ef; --sidebar: #f4f2ee; --ink: #3d4038; --muted: #7a7a6e; --accent: #7a523b; --rule: rgb(61 64 56 / 0.1); }
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { width: 1200px; height: 630px; overflow: hidden; }
body {
  background: radial-gradient(120% 90% at 50% 0%, #fbf9f4 0%, var(--paper) 55%, #f3efe5 100%);
  color: var(--ink); font-family: "Newsreader", Georgia, serif; font-optical-sizing: auto;
  -webkit-font-smoothing: antialiased; display: flex; flex-direction: column; align-items: center;
}
.icon { width: 88px; height: 88px; margin-top: 52px; filter: drop-shadow(0 6px 14px rgb(60 50 40 / 0.14)); }
h1 { margin-top: 26px; font-size: 76px; font-weight: 500; line-height: 1.04; letter-spacing: -0.018em; text-align: center; }
.sub { margin-top: 22px; font-size: 30px; color: var(--muted); text-align: center; line-height: 1.35; max-width: 900px; }
.site { position: absolute; bottom: 44px; font-size: 26px; color: var(--accent); letter-spacing: 0.01em; }

/* A slice of the editor window, cropped by the bottom edge. */
.window {
  position: absolute; top: 400px; left: 130px; width: 940px; height: 300px; display: flex;
  background: var(--paper); border: 1px solid var(--rule); border-radius: 16px; overflow: hidden;
  box-shadow: 0 1px 2px rgb(0 0 0 / 0.04), 0 22px 60px -20px rgb(60 50 40 / 0.32);
}
.lights { position: absolute; left: 18px; top: 16px; display: flex; gap: 8px; }
.lights i { width: 12px; height: 12px; border-radius: 50%; display: block; }
.sidebar { width: 200px; background: var(--sidebar); padding: 50px 14px 0; }
.row { height: 10px; border-radius: 5px; background: rgb(61 64 56 / 0.12); margin: 12px 6px; }
.row.sel { background: rgb(61 64 56 / 0.06); height: 40px; margin: 6px 0; padding: 9px 8px; }
.row.sel b { display: block; font-size: 15px; font-weight: 600; line-height: 1; color: var(--ink); }
.page { flex: 1; padding: 34px 0 0 48px; position: relative; }
.title { font-size: 31px; font-weight: 700; letter-spacing: -0.01em; }
.goal { margin-top: 6px; font-size: 17px; color: var(--muted); font-style: italic; }
.para { margin-top: 16px; font-size: 18px; line-height: 1.55; width: 390px; }
.mark { text-decoration: underline; text-decoration-color: rgb(122 82 59 / 0.55); text-decoration-thickness: 1.5px; text-underline-offset: 4px; white-space: nowrap; background: rgb(122 82 59 / 0.07); }
.card {
  position: absolute; left: 462px; top: 92px; width: 236px; padding: 14px 16px; border-radius: 10px;
  border: 1px solid var(--rule); background: var(--paper); box-shadow: 0 2px 6px rgb(0 0 0 / 0.05);
  font-size: 15.5px; line-height: 1.45;
}
.card .who { font-weight: 600; font-size: 14px; color: var(--accent); margin-bottom: 4px; }
`;

const editor = `
<div class="window">
  <div class="lights"><i style="background:#ec6a5ecc"></i><i style="background:#f4bf4fcc"></i><i style="background:#61c554cc"></i></div>
  <div class="sidebar">
    <div class="row sel"><b>Letter to Anna</b></div>
    <div class="row" style="width:70%"></div><div class="row" style="width:82%"></div><div class="row" style="width:60%"></div>
  </div>
  <div class="page">
    <div class="title">Letter to Anna</div>
    <div class="goal">Tell her why I'm moving back.</div>
    <p class="para">The plants went to the neighbours, the books to the shop on the corner. <span class="mark">The city never really felt like home.</span></p>
    <div class="card"><div class="who">Matilde</div>Is this sentence what you feel, or what's easier to tell her?</div>
  </div>
</div>`;

const pages = [
  {
    file: "og-image.png",
    body: `<img class="icon" src="${icon}" alt=""><h1>You write every word.<br>Matilde reads along.</h1>${editor}`,
  },
  {
    file: "og-image-privacy.png",
    body: `<img class="icon" src="${icon}" alt="" style="margin-top:120px"><h1>How privacy works</h1>
      <p class="sub">Your writing stays on your Mac. When you sync, your notes are encrypted on your devices, so no one else can read them.</p>
      <div class="site">matilde.page</div>`,
  },
];

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
for (const { file, body } of pages) {
  await page.setContent(`<!doctype html><html><head><style>${css}</style></head><body>${body}</body></html>`);
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: resolve(root, "public", file), type: "png" });
  console.log(`public/${file}`);
}
await browser.close();
