// The site's pages for search engines and crawlers. Add new pages here (the 404 page stays out).
import type { APIRoute } from "astro";

const pages = ["/", "/privacy"];

export const GET: APIRoute = ({ site }) => {
  const urls = pages.map((path) => `  <url><loc>${new URL(path, site).href}</loc></url>`).join("\n");
  const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
  return new Response(body, { headers: { "Content-Type": "application/xml; charset=utf-8" } });
};
