// The dashboard: one server-rendered HTML page, no scripts, no external requests.
import type { EventRow, ReleaseDownloads, Result, VisitDay } from "./sources";
import { lastDays, series, windows } from "./sources";
import type { SyncStats } from "./types";

export interface PageData {
  nowMs: number;
  events: Result<EventRow[]>;
  visits: Result<VisitDay[]> | null;
  releases: Result<ReleaseDownloads[]>;
  sync: Result<SyncStats>;
}

export function escapeHtml(value: unknown): string {
  return String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

const fmt = (n: number) => Math.round(n).toLocaleString("en-US");

/** A small bar chart of daily values, oldest left. */
export function bars(values: number[], days: string[], label: string): string {
  const width = 300;
  const height = 56;
  const max = Math.max(1, ...values);
  const step = width / Math.max(1, values.length);
  const rects = values
    .map((v, i) => {
      const h = v === 0 ? 1 : Math.max(2, (v / max) * (height - 4));
      return `<rect x="${(i * step + 1).toFixed(1)}" y="${(height - h).toFixed(1)}" width="${Math.max(1, step - 2).toFixed(1)}" height="${h.toFixed(1)}" rx="1.5"${v === 0 ? ' class="zero"' : ""}><title>${escapeHtml(days[i])}: ${fmt(v)}</title></rect>`;
    })
    .join("");
  return `<svg class="chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="${escapeHtml(label)}, last ${values.length} days">${rects}</svg>`;
}

function figures(values: number[]): string {
  const w = windows(values);
  return `<dl class="figures"><div><dt>Today</dt><dd>${fmt(w.today)}</dd></div><div><dt>7 days</dt><dd>${fmt(w.week)}</dd></div><div><dt>30 days</dt><dd>${fmt(w.month)}</dd></div></dl>`;
}

function metric(title: string, note: string, values: number[], days: string[]): string {
  return `<section class="metric"><h3>${escapeHtml(title)}</h3>${figures(values)}${bars(values, days, title)}<p class="note">${note}</p></section>`;
}

function unavailable(title: string, result: { ok: false; error: string }, hint = ""): string {
  return `<section class="metric missing"><h3>${escapeHtml(title)}</h3><p class="note">Not available: ${escapeHtml(result.error)}.${hint ? ` ${hint}` : ""}</p></section>`;
}

function table(head: string[], rows: (string | number)[][]): string {
  if (rows.length === 0) return `<p class="note">Nothing yet.</p>`;
  const cell = (v: string | number, i: number) => `<td${i > 0 ? ' class="num"' : ""}>${typeof v === "number" ? fmt(v) : escapeHtml(v)}</td>`;
  return `<table><thead><tr>${head.map((h, i) => `<th${i > 0 ? ' class="num"' : ""}>${escapeHtml(h)}</th>`).join("")}</tr></thead><tbody>${rows
    .map((r) => `<tr>${r.map(cell).join("")}</tr>`)
    .join("")}</tbody></table>`;
}

function tally(rows: EventRow[], key: "version" | "os", days: Set<string>): [string, number][] {
  const totals = new Map<string, number>();
  for (const r of rows) if (days.has(r.day)) totals.set(r[key], (totals.get(r[key]) ?? 0) + r.count);
  return [...totals.entries()].sort((a, b) => b[1] - a[1]);
}

function versionSort(a: string, b: string): number {
  const parts = (v: string) => v.split(".").map((p) => Number(p));
  const [pa, pb] = [parts(a), parts(b)];
  for (let i = 0; i < 3; i++) if ((pa[i] ?? -1) !== (pb[i] ?? -1)) return (pb[i] ?? -1) - (pa[i] ?? -1);
  return 0;
}

export function renderPage(data: PageData): string {
  const days = lastDays(data.nowMs);
  const week = new Set(days.slice(-7));
  const parts: string[] = [];

  // Website
  parts.push(`<h2>Website</h2><div class="grid">`);
  if (data.visits === null) {
    parts.push(
      `<section class="metric missing"><h3>Visits</h3><p class="note">Set <code>WEB_ANALYTICS_SITE_TAG</code> to show visits here (docs/stats.md). Until then, see <a href="https://dash.cloudflare.com/?to=/:account/web-analytics">Web Analytics</a>.</p></section>`,
    );
  } else if (data.visits.ok) {
    const visits = series(data.visits.value.map((v) => ({ day: v.day, value: v.visits })), days);
    parts.push(metric("Visits", "Cloudflare Web Analytics: visits to matilde.page (a visit is a page view from another site or typed in). No cookies; browsers that block the beacon aren't counted.", visits, days));
  } else {
    parts.push(unavailable("Visits", data.visits));
  }
  if (data.events.ok) {
    const downloads = series(data.events.value.filter((r) => r.event === "download").map((r) => ({ day: r.day, value: r.count })), days);
    parts.push(metric("Download clicks", "Clicks on Download (matilde.page/download), bots and link previews left out. A click isn't always a finished download.", downloads, days));
  } else {
    parts.push(unavailable("Download clicks", data.events));
  }
  parts.push(`</div>`);

  // Releases
  parts.push(`<h2>GitHub downloads</h2>`);
  if (data.releases.ok) {
    const rows = data.releases.value.map((r) => [r.tag, r.publishedAt, r.dmg, r.appcast] as (string | number)[]);
    const totalDmg = data.releases.value.reduce((a, r) => a + r.dmg, 0);
    parts.push(
      `<p class="lede">${fmt(totalDmg)} DMG downloads across all releases.</p>`,
      table(["Release", "Published", "Matilde.dmg", "appcast.xml"], rows),
      `<p class="note">All-time counts per release from GitHub, refreshed hourly. Matilde.dmg counts new downloads and in-app updates alike (both fetch the DMG). appcast.xml counts update checks that went straight to GitHub, from installs still on the old feed address.</p>`,
    );
  } else {
    parts.push(unavailable("Releases", data.releases));
  }

  // Update checks
  parts.push(`<h2>Macs</h2>`);
  if (data.events.ok) {
    const checks = data.events.value.filter((r) => r.event === "appcast");
    const perDay = series(checks.map((r) => ({ day: r.day, value: r.count })), days);
    const fullWeek = perDay.slice(-8, -1);
    const estimate = fullWeek.reduce((a, b) => a + b, 0) / Math.max(1, fullWeek.length);
    const versions = tally(checks, "version", week).sort((a, b) => versionSort(a[0], b[0]));
    const systems = tally(checks, "os", week).map(([os, n]) => [os === "unknown" ? "unknown (0.3.1 and older)" : `macOS ${os}`, n] as [string, number]);
    parts.push(
      `<div class="grid">`,
      metric("Update checks per day", "Requests for matilde.page/appcast.xml. Matilde looks for updates about once a day while it runs, and again when someone chooses Check for Updates.", perDay, days),
      `<section class="metric"><h3>Macs a day <span class="estimate">estimate</span></h3><p class="big">≈ ${fmt(estimate)}</p><p class="note">Average update checks per day over the last 7 full days. Since each Mac checks about once a day, this roughly matches the Macs that opened Matilde. Installs from before the feed moved aren't included (see appcast.xml above).</p></section>`,
      `</div><div class="grid">`,
      `<section><h3>By version, last 7 days</h3>${table(["Version", "Checks"], versions)}</section>`,
      `<section><h3>By macOS, last 7 days</h3>${table(["System", "Checks"], systems)}</section>`,
      `</div>`,
    );
  } else {
    parts.push(unavailable("Update checks", data.events));
  }

  // Sync and feedback
  parts.push(`<h2>Sync</h2>`);
  if (data.sync.ok) {
    const s = data.sync.value;
    const c = s.current;
    const devices = Object.entries(c.devices).sort((a, b) => b[1] - a[1]);
    const label = (p: string) => ({ macos: "Mac", ios: "iPhone", ipados: "iPad" })[p] ?? p;
    const newAccounts = series(s.newAccounts, days);
    const feedback = series(s.feedback.map((f) => ({ day: f.day, value: f.value })), days);
    const kinds = new Map<string, number>();
    for (const f of s.feedback) if (week.has(f.day)) kinds.set(f.kind, (kinds.get(f.kind) ?? 0) + f.value);
    const snapshot = (name: string) => series(s.daily[name] ?? [], days);
    parts.push(
      `<dl class="figures wide">`,
      `<div><dt>Accounts</dt><dd>${fmt(c.accounts)}</dd></div>`,
      `<div><dt>Active, 7 days</dt><dd>${fmt(c.active7d)}</dd></div>`,
      `<div><dt>Active, 30 days</dt><dd>${fmt(c.active30d)}</dd></div>`,
      `<div><dt>Devices</dt><dd>${fmt(devices.reduce((a, [, n]) => a + n, 0))}</dd></div>`,
      `<div><dt>Notes and drafts</dt><dd>${fmt(c.draftsLive)}</dd></div>`,
      `<div><dt>Encrypted records</dt><dd>${fmt(c.recordsLive)}</dd></div>`,
      `</dl>`,
      `<p class="note">Devices: ${devices.length ? devices.map(([p, n]) => `${escapeHtml(label(p))} ${fmt(n)}`).join(", ") : "none"}. Active means a signed-in device of the account checked in that day. Notes and drafts counts every synced draft, alternates included; records counts everything stored (drafts, bodies, comments, assets, …). Only counts: what's in them stays encrypted.</p>`,
      `<div class="grid">`,
      metric("New accounts", "Accounts created per day. Deleted accounts drop out.", newAccounts, days),
      `<section class="metric"><h3>Active accounts, 7 days</h3>${bars(snapshot("active_7d"), days, "Active accounts")}<p class="note">Daily snapshot from the server's cron, since stats began.</p></section>`,
      `</div>`,
      `<h2>Feedback</h2><div class="grid">`,
      metric("Feedback sent", `From the apps. Last 7 days: ${[...kinds.entries()].map(([k, n]) => `${escapeHtml(k)} ${fmt(n)}`).join(", ") || "none"}.`, feedback, days),
      `</div>`,
    );
  } else {
    parts.push(unavailable("Sync", data.sync, "The production sync server needs the StatsApi entrypoint (deployed with this change)."));
  }

  const updated = new Date(data.nowMs).toISOString().slice(0, 16).replace("T", " ");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Matilde · Stats</title>
<style>${STYLE}</style>
</head>
<body>
<main>
<header><h1>Matilde in numbers</h1><p class="note">Anonymous counts only. Days are UTC. Updated ${escapeHtml(updated)} UTC.</p></header>
${parts.join("\n")}
</main>
</body>
</html>`;
}

const STYLE = `
:root{--paper:#f9f6ef;--card:#fffdf8;--ink:#3d4038;--muted:#7a7a6e;--accent:#7a523b;--rule:rgb(61 64 56/.09);color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--paper:#212222;--card:#262727;--ink:#dedddb;--muted:#9e9fa1;--accent:#b0a699;--rule:rgb(222 221 219/.1)}}
*{box-sizing:border-box}
html{background:var(--paper);color:var(--ink);-webkit-font-smoothing:antialiased}
body{margin:0;font:15px/1.5 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
main{max-width:960px;margin:0 auto;padding:48px 24px 80px}
h1,h2,h3{font-family:"Newsreader","Iowan Old Style",Georgia,serif;font-weight:600;letter-spacing:-.01em}
h1{font-size:38px;margin:0 0 4px;font-weight:500}
h2{font-size:25px;margin:44px 0 14px;padding-top:20px;border-top:1px solid var(--rule)}
h3{font-size:19px;margin:0 0 8px}
a{color:var(--accent)}
code{font-size:13px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;margin-bottom:16px}
section{background:var(--card);border:1px solid var(--rule);border-radius:14px;padding:18px 20px}
.missing{opacity:.8}
.figures{display:flex;gap:24px;margin:0 0 10px}
.figures.wide{flex-wrap:wrap;gap:16px 36px}
.figures div{min-width:0}
dt{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
dd{margin:0;font-family:"Newsreader","Iowan Old Style",Georgia,serif;font-size:28px;font-variant-numeric:tabular-nums}
.big{font-family:"Newsreader","Iowan Old Style",Georgia,serif;font-size:40px;margin:0}
.lede{font-size:17px;margin:0 0 10px}
.estimate{font:500 11px/1 ui-sans-serif,-apple-system,system-ui,sans-serif;text-transform:uppercase;letter-spacing:.06em;color:var(--accent);border:1px solid currentColor;border-radius:999px;padding:3px 7px;vertical-align:middle}
.chart{display:block;width:100%;height:56px;fill:var(--accent)}
.chart .zero{fill:var(--rule)}
.note{color:var(--muted);font-size:13px;margin:10px 0 0}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--rule)}
th{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);font-weight:500}
.num{text-align:right}
`;
