// A shared save's page with the save already in it. Chats and the share
// sheet read the page's title and image without running its script, so
// without this every save previews as the same generic card. The save also
// rides along in the page, so it shows without a second trip.

import { photo, shared } from "../../lib/share.js";
import { where } from "../../src/js/when.js";

// A preview is kept by the chat it lands in, so it says the dates as they
// are rather than "today".
const short = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
const long = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const day = (iso) => new Date(`${iso}T12:00:00Z`);

function dates({ starts_on: from, ends_on: to }) {
  if (!from && !to) return "";
  if (!to || from === to) return long.format(day(from ?? to));
  if (!from) return `Until ${long.format(day(to))}`;
  return `${short.format(day(from))} – ${long.format(day(to))}`;
}

const content = (value) => ({ element: (el) => el.setAttribute("content", value) });

export async function onRequestGet({ request, params, env }) {
  const page = await env.ASSETS.fetch(new URL("/s/", request.url));
  const save = await shared(params.token);
  if (!save) return page;
  const { card, from } = save;

  const description = [from ? `From ${from}` : "", where(card), dates(card)].filter(Boolean).join(" · ") ||
    card.summary || "";
  const image = photo(card) ?? new URL("/img/share-icon.png", request.url).href;

  const res = new HTMLRewriter()
    .on("title", { element: (el) => el.setInnerContent(`${card.title} · Can We Go?`) })
    .on('meta[property="og:title"]', content(card.title))
    .on('meta[property="og:description"]', content(description))
    .on('meta[name="description"]', content(description))
    .on('meta[property="og:image"]', content(image))
    .on('meta[name="twitter:card"]', content(photo(card) ? "summary_large_image" : "summary"))
    .on("body", { element: (el) => el.setAttribute("data-preload", JSON.stringify({ card, from })) })
    .transform(page);
  const out = new Response(res.body, res);
  out.headers.set("Cache-Control", "public, max-age=60");
  return out;
}
