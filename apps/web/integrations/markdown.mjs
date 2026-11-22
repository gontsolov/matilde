// After the build, writes a Markdown copy of each page for AI agents and LLMs, from the same HTML
// people get: dist/index.md, dist/privacy.md, and dist/llms-full.txt (public/llms.txt followed by
// both pages). Only <main> is converted; the interactive editor mock-up, decorative and hidden
// parts and the floating Download button are left out.
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { NodeHtmlMarkdown } from "node-html-markdown";
import { parse } from "node-html-parser";

const SITE = "https://matilde.page";
/** Built page → Markdown file and the page's public URL. */
const PAGES = [
  { html: "index.html", md: "index.md", url: `${SITE}/` },
  { html: "privacy.html", md: "privacy.md", url: `${SITE}/privacy` },
];
const SKIP = ["[data-mockup]", "[data-md-skip]", "[aria-hidden=true]", "script", "style", "svg", "img"];

const nhm = new NodeHtmlMarkdown({ bulletMarker: "-", keepDataImages: false });

export function pageToMarkdown(html, url) {
  const doc = parse(html);
  const main = doc.querySelector("main");
  if (!main) throw new Error(`No <main> in ${url}`);
  for (const selector of SKIP) for (const node of main.querySelectorAll(selector)) node.remove();
  // Relative links become absolute, so the Markdown works on its own.
  for (const a of main.querySelectorAll("a[href]")) {
    const href = a.getAttribute("href");
    if (href && !/^[a-z]+:/i.test(href)) a.setAttribute("href", new URL(href, url).href);
  }
  // A definition list reads best as one paragraph per term.
  for (const div of main.querySelectorAll("dl > div")) {
    const term = div.querySelector("dt")?.innerHTML ?? "";
    const text = div.querySelector("dd")?.innerHTML ?? "";
    div.replaceWith(`<p><strong>${term}</strong> ${text}</p>`);
  }
  // A line break inside a heading is only for the layout.
  for (const br of main.querySelectorAll("h1 br, h2 br, h3 br")) br.replaceWith(" ");
  const title = doc.querySelector("title")?.text.trim();
  const description = doc.querySelector('meta[name="description"]')?.getAttribute("content");
  const body = nhm.translate(main.innerHTML.replace(/\s+/g, " ")).replace(/\n{3,}/g, "\n\n").trim();
  return `<!-- ${title}: ${url} -->\n<!-- ${description} -->\n\n${body}\n`;
}

/** @returns {import("astro").AstroIntegration} */
export default function markdown() {
  return {
    name: "matilde-markdown",
    hooks: {
      "astro:build:done": async ({ dir, logger }) => {
        const out = (file) => fileURLToPath(new URL(file, dir));
        const parts = [await readFile(out("llms.txt"), "utf8")];
        for (const page of PAGES) {
          const md = pageToMarkdown(await readFile(out(page.html), "utf8"), page.url);
          await writeFile(out(page.md), md);
          parts.push(md);
          logger.info(page.md);
        }
        await writeFile(out("llms-full.txt"), parts.join("\n---\n\n"));
        logger.info("llms-full.txt");
      },
    },
  };
}
