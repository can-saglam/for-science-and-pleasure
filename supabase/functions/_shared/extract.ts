import Anthropic from "npm:@anthropic-ai/sdk";
import { EVENT_CATEGORIES, normaliseCategory, PLACE_CATEGORIES } from "./categories.ts";
import {
  colorFromImageBytes,
  colorFromImageUrl,
  heroImageFromHtml,
  heroImageFromUrl,
  wikipediaImage,
  wikipediaQueries,
} from "./color.ts";
import { corsHeaders, geocode, resolveMapsLink } from "./geo.ts";
import { findPlace, type PlaceMatch, photoUri, placePhotoLink } from "./places.ts";
import {
  geocodeNearHome,
  type Home,
  homeLabel,
  homeToday,
  LONDON,
  priceExamples,
} from "./home.ts";
import {
  fetchImageBase64,
  fetchSocialPost,
  socialPlatform,
  SocialUnreadableError,
} from "./social.ts";

export { corsHeaders, geocode, SocialUnreadableError };

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export interface ParsedCard {
  kind: "event" | "place";
  title: string;
  summary: string | null;
  venue: string | null;
  area: string | null;
  address: string | null;
  category: string | null;
  price: string | null;
  booking_url: string | null;
  starts_on: string | null;
  ends_on: string | null;
  website: string | null;
}

/// Thrown when the input is a search, not a save — "modern art museums in
/// London", "good ramen", "gigs this weekend". A named venue plus "latest
/// exhibition" is a save (the hero show still open), not this error.
/// Nothing is stored; the caller shows the message and asks for something
/// more specific.
export class VagueInputError extends Error {
  constructor() {
    super(
      "That reads like a search, not a save. Name one place or event (a venue, a show, a restaurant) or paste a link to it.",
    );
    this.name = "VagueInputError";
  }
}

/// What the model returns: the card plus its own reading of whether the
/// input pointed at one real thing, and the thing's own page. Neither
/// leaves this module as is — the page becomes the save's url once checked.
type ModelCard = ParsedCard & { is_specific: boolean; link: string | null };

// The schema carries the home in its examples (area, price, address), so
// it is built per call rather than once.
const cardSchema = (home: Home) => ({
  type: "object",
  properties: {
    is_specific: {
      type: "boolean",
      description:
        "true if the user's input points at one particular, real, named event or place (a venue, an exhibition, a restaurant, a gig). Also true when they name one venue or institution and ask for its current, latest, or highlighted exhibition or show — that is a save: resolve it to the exhibition the venue's own site is currently featuring that is still open today. A postponed, cancelled, or already-closed show is not that. Likewise one named artist, performer or company plus 'latest', 'current' or 'next' show: resolve it to that show (still open or upcoming), preferring one in or near the user's home city. false when it is a category, a list, or an unbounded search that names no particular place — 'modern art museums in London', 'good brunch spots', 'things to do this weekend', 'exhibitions in Singapore' — even if web search turned up candidates; never pick one museum or gig to stand in for a request that named no venue.",
    },
    kind: {
      type: "string",
      enum: ["event", "place"],
      description:
        "'event' if it has dates or a run (exhibition, gig, festival, pop-up); 'place' if it's evergreen (cafe, restaurant, bar, shop, park)",
    },
    title: {
      type: "string",
      description:
        "Short name of the event or place, as its organiser or venue lists it — for an exhibition, the show's official title (often just the artist's name). Never append the venue, city or dates ('… at Hayward Gallery'); those have their own fields.",
    },
    summary: {
      type: ["string", "null"],
      description: "One sentence on what it is and why it's interesting",
    },
    venue: { type: ["string", "null"], description: "Venue or institution name" },
    area: {
      type: ["string", "null"],
      description:
        home.locality
          ? `Neighbourhood or district within its city (for ${home.locality}, the kind of name a local would use)`
          : "Neighbourhood or district within its city",
    },
    address: {
      type: ["string", "null"],
      description:
        home.locality
          ? `Street address. Include the city (and country) when it is not ${home.locality} — e.g. '12 Rue de Rivoli, Paris, France'`
          : "Street address, including city and country",
    },
    category: {
      type: ["string", "null"],
      description:
        `For an event, one of: ${EVENT_CATEGORIES.join(", ")}. ` +
        `For a place, one of: ${PLACE_CATEGORIES.join(", ")}. ` +
        "A gallery, sculpture park or museum saved as a place is 'gallery' or 'museum', never 'exhibition' — that word is for a dated show.",
    },
    price: { type: ["string", "null"], description: priceExamples(home) },
    booking_url: { type: ["string", "null"] },
    starts_on: {
      type: ["string", "null"],
      description: "Opening/start date as YYYY-MM-DD, null if unknown or a place",
    },
    ends_on: {
      type: ["string", "null"],
      description: "Closing/end date as YYYY-MM-DD; for a one-day event same as starts_on",
    },
    website: {
      type: ["string", "null"],
      description:
        "Official homepage URL for this exact event or place — the venue's own site, not an aggregator, social media, or maps link; null unless confidently known",
    },
    link: {
      type: ["string", "null"],
      description:
        "The web page for this exact event or place, opened when someone taps the save. An event: its own main page — its listing on the venue's or organiser's site, the homepage of a festival or fair with a site of its own, or the official ticket page when that is where the organiser lists it. A place: its official homepage (for one branch of a chain, that branch's page). Never a sub-page such as about, FAQs, visitor information or checkout. Only a URL that appeared in the input, the fetched page, or your search results — never one you constructed. null when there is no such page: never a venue homepage or what's-on list standing in for an event, an aggregator, social media, or a maps link.",
    },
  },
  required: [
    "is_specific", "kind", "title", "summary", "venue", "area", "address",
    "category", "price", "booking_url", "starts_on", "ends_on", "website", "link",
  ],
  additionalProperties: false,
}) as const;

const URL_RE = /https?:\/\/\S+/i;

export function firstUrl(text: string): string | null {
  const m = text.match(URL_RE);
  return m ? m[0].replace(/[)\],.]+$/, "") : null;
}

function isFetchable(url: string): boolean {
  try {
    const host = new URL(url).hostname;
    return !/(^|\.)instagram\.com$|(^|\.)facebook\.com$|(^|\.)tiktok\.com$/.test(host);
  } catch {
    return false;
  }
}

// The model is told never to hand back a maps link as the "official
// website", but belt-and-braces: fetching one only ever yields the Google
// Maps app icon, never a photo of the place.
function isMapsUrl(url: string): boolean {
  try {
    const u = new URL(url);
    const host = u.hostname.toLowerCase();
    if (host.includes("maps.google") || host === "maps.app.goo.gl") return true;
    if (host === "goo.gl" || host.endsWith("google.com")) {
      return u.pathname.startsWith("/maps") || host.startsWith("maps.");
    }
    return false;
  } catch {
    return true;
  }
}

// Ticketing sites (See Tickets, Ticketmaster…) often serve a bot-challenge
// page to server-side fetches. Treat those as "no page" so the model falls
// back to web search instead of reading the challenge text.
const BLOCK_PAGE_RE =
  /unusual traffic|unusual activity|access denied|are you a robot|captcha|just a moment|attention required|pardon our interruption|request blocked|verify you are human|enable javascript and cookies/i;

function looksBlocked(pageText: string): boolean {
  return pageText.length < 4000 && BLOCK_PAGE_RE.test(pageText);
}

// Query parameters that only say where a click came from.
const TRACKING_PARAM_RE =
  /^(utm_\w+|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|_gl|_ga|igsh|igshid|ref_src|aff|sg)$/i;

export function cleanLink(raw: string): string | null {
  try {
    const u = new URL(raw.trim());
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    for (const key of [...u.searchParams.keys()]) {
      if (TRACKING_PARAM_RE.test(key)) u.searchParams.delete(key);
    }
    return u.toString();
  } catch {
    return null;
  }
}

/// Two spellings of one page compare equal: no www, trailing slash,
/// fragment or tracking.
export function linkKey(raw: string): string | null {
  const clean = cleanLink(raw);
  if (!clean) return null;
  const u = new URL(clean);
  return `${u.hostname.toLowerCase().replace(/^www\./, "")}${u.pathname.replace(/\/+$/, "")}${u.search}`;
}

const MONTHS = [
  "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];

function pageText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ");
}

/// Does a page name this date — "13 November", "Nov 13th", "13/11/2026",
/// or 2026-11-13 in its markup?
export function mentionsDate(html: string, iso: string): boolean {
  if (html.includes(iso)) return true;
  const [y, m, d] = iso.split("-").map(Number);
  if (!y || !m || !d || m > 12) return false;
  const text = pageText(html);
  if (!text.includes(String(y))) return false;
  const day = `0?${d}(?:st|nd|rd|th)?`;
  const month = `${MONTHS[m - 1]}[a-z]*\\.?`;
  return new RegExp(
    `\\b${day}\\s+${month}(?![a-z])|\\b${month}\\s+${day}\\b|\\b0?${d}[/.]0?${m}[/.](?:${y}|${y % 100})\\b`,
    "i",
  ).test(text);
}

const MONTH_NAME = `(?:${MONTHS.join("|")})[a-z]*\\.?`;
const FULL_DATE_RE = new RegExp(
  `\\b\\d{1,2}(?:st|nd|rd|th)?\\s+${MONTH_NAME},?\\s+(20\\d\\d)\\b|\\b${MONTH_NAME}\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+(20\\d\\d)\\b`,
  "gi",
);

/// Is this page about this run of the event? Sites reuse an event's
/// address for other years' runs (`/sarathy-korwar` is the 2020 gig, `-4`
/// this year's). A page naming the event's date is; one whose full dates
/// are all in other years isn't — even when the model's dates are a little
/// off, the right page still dates it in the right years. A page with no
/// full dates can't say, so it's kept.
export function isThisRun(html: string, dates: string[]): boolean {
  if (!dates.length || dates.some((d) => mentionsDate(html, d))) return true;
  const years = new Set(dates.map((d) => d.slice(0, 4)));
  const found = [...pageText(html).matchAll(FULL_DATE_RE)].map((m) => m[1] ?? m[2]);
  return !found.length || found.some((y) => years.has(y));
}

function isSiteRoot(url: string): boolean {
  return new URL(url).pathname.replace(/\/+$/, "") === "";
}

/// The model's `link`, kept only if it leads somewhere real: the page
/// loads, or the site walls off servers but search showed the model that
/// exact page. A dead or guessed deep link is dropped, never swapped for
/// the site's homepage — two shows at one venue would then share a link
/// and read as duplicates of each other.
async function ownPage(
  candidate: string,
  seen: Set<string>,
  dates: string[],
): Promise<{ url: string; html: string | null } | null> {
  const clean = cleanLink(candidate);
  if (!clean || !isFetchable(clean) || isMapsUrl(clean)) return null;
  const vouched = () => {
    const key = linkKey(clean);
    return key && seen.has(key) ? { url: clean, html: null } : null;
  };
  try {
    const res = await fetch(clean, {
      redirect: "follow",
      signal: AbortSignal.timeout(8_000),
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml",
      },
    });
    if (!res.ok) {
      await res.body?.cancel();
      return res.status === 404 || res.status === 410 ? null : vouched();
    }
    const html = (await res.text()).slice(0, 600_000);
    if (looksBlocked(html.replace(/<[^>]+>/g, " "))) return vouched();
    const final = cleanLink(res.url || clean) ?? clean;
    // Sites that answer a missing page by redirecting home.
    if (isSiteRoot(final) && !isSiteRoot(clean)) return null;
    if (!isThisRun(html, dates)) return null;
    return { url: final, html };
  } catch {
    return vouched();
  }
}

async function fetchPage(
  url: string,
): Promise<{ text: string; ogImage: string | null } | null> {
  try {
    const res = await fetch(url, {
      redirect: "follow",
      signal: AbortSignal.timeout(15_000),
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml",
      },
    });
    if (!res.ok) return null;
    // Cap the HTML before running regexes over it — pathological pages
    // (Google Maps is ~20MB of JS) would blow the worker's CPU budget.
    const html = (await res.text()).slice(0, 600_000);
    // Keep <title> and meta descriptions, then strip tags from the body.
    const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "";
    const metas = [...html.matchAll(/<meta[^>]+(?:name|property)=["'][^"']*(?:description|title|og:)[^"']*["'][^>]*content=["']([^"']*)["']/gi)]
      .map((m) => m[1]);
    const body = html
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;|&amp;|&quot;|&#\d+;|&[a-z]+;/gi, " ")
      .replace(/\s+/g, " ")
      .trim();
    return {
      text: [title, metas.join("\n"), body].join("\n\n").slice(0, 30_000),
      // og:image first, then JSON-LD and the page's largest picture — the
      // same ladder the model's suggested website gets. Gallery and
      // festival sites often skip social meta tags entirely.
      ogImage: heroImageFromHtml(html, res.url || url),
    };
  } catch {
    return null;
  }
}

/// Does this card point at somewhere real? A source link, an official site,
/// coordinates or a street address all do. An event may also stand on a
/// named venue or a date — "Frieze London, October" is a real thing even
/// when geocoding fails. A place with none of these is a phantom.
export function isAnchored(
  card: Pick<ParsedCard, "kind" | "website" | "address" | "venue" | "starts_on">,
  from: { url: string | null; coords: { lat: number; lng: number } | null },
): boolean {
  if (from.url || from.coords) return true;
  if (card.website || card.address) return true;
  return card.kind === "event" && Boolean(card.venue || card.starts_on);
}

export interface ExtractInput {
  text?: string;          // pasted text, forwarded message, or a bare URL
  image_base64?: string;  // screenshot (e.g. of an Instagram post)
  image_media_type?: string;
}

export async function extractCard(
  input: ExtractInput,
  home: Home = LONDON,
): Promise<
  ParsedCard & {
    url: string | null;
    source: string;
    lat: number | null;
    lng: number | null;
    color: string | null;
    image_url: string | null;
  }
> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

  const text = (input.text ?? "").trim();
  const url = text ? firstUrl(text) : null;
  // Google Maps links: never fetch the page (it's huge, JS-only junk); the
  // URL itself names the place and pins its coordinates.
  const mapsLink = url ? await resolveMapsLink(url) : null;
  let page: { text: string; ogImage: string | null } | null = null;
  if (url && !mapsLink && isFetchable(url)) {
    page = await fetchPage(url);
    if (page && looksBlocked(page.text)) page = null;
  }
  const pageText = page?.text ?? null;

  // Social links (Instagram, TikTok, Facebook) have no readable page, but
  // their caption and cover are reachable without a login — see social.ts.
  // The cover is fetched as bytes for the model to read the on-screen text;
  // its URL is signed and expiring, so it is never stored as the thumbnail.
  const social = url && !mapsLink ? socialPlatform(url) : null;
  const post = social ? await fetchSocialPost(url!) : null;
  const cover = post?.image && !input.image_base64
    ? await fetchImageBase64(post.image)
    : null;
  // The user's own words beyond the bare link — a name they typed after
  // it, or a caption the app fetched on-device when this server couldn't.
  const ownWords = url ? text.replace(url, "").trim() : text;
  if (social && !post && !ownWords && !input.image_base64) {
    // Nothing from the platform, nothing from the user: asking beats a
    // card invented from a URL slug.
    throw new SocialUnreadableError(social);
  }

  // A link we couldn't read: let the model search the web for the real
  // details instead of guessing from the URL slug alone. Every maps link
  // searches too — a pin carries no page to read, so the official website
  // (and with it the thumbnail photo) can only come from search. Bare
  // typed names and screenshots search for the same reason: without a
  // page there is no other route to verified details or a venue photo.
  // Social posts always search: a caption names a place, the web confirms
  // it and finds the official site.
  const useWebSearch =
    Boolean(url && !mapsLink && !pageText) ||
    Boolean(mapsLink) ||
    Boolean(!url && (text || input.image_base64));

  // Card accent colour: a screenshot beats the page's og:image because it is
  // exactly what the user saw. Best-effort; null is fine.
  const colorPromise: Promise<string | null> = input.image_base64
    ? colorFromImageBytes(base64ToBytes(input.image_base64))
    : cover
      ? colorFromImageBytes(base64ToBytes(cover.base64))
      : page?.ogImage
        ? colorFromImageUrl(page.ogImage)
        : Promise.resolve(null);

  const today = homeToday(home);
  const where = homeLabel(home);
  const parts: string[] = [
    `Today's date is ${today}. Extract a structured card for an events/places app.`,
    `The user lives in ${where}: assume that city when the source doesn't say where something is, and read prices, dates and place names with that in mind. But trust the source — if it clearly places the event or venue somewhere else, keep it there (with the city in the address); never move it home.`,
    "Resolve relative or partial dates to absolute YYYY-MM-DD dates (if a month is named without a year, assume the next occurrence from today).",
    "If a field is genuinely unknown, use null — do not guess venues, prices, or dates.",
    "If the input is a category, a list, or a search that names no particular venue — 'modern art museums in London', 'gigs this weekend' — set is_specific to false and do not choose a candidate to stand in for it. If they name one venue and ask for the current, latest, or highlighted exhibition or show there, that is specific: set is_specific true and fill the card for a special exhibition the venue's own website currently lists as on. Source of truth is the official 'ongoing' / 'what's on' list, not a highlights carousel, yearly lineup, TimeOut page, or news of a planned show. The show must still be open today (started on or before today, not yet closed); postponed, cancelled, or 404 pages do not count. If they said 'latest' or 'newest', pick the most recently opened special exhibition that is still open; otherwise pick the first special exhibition on that official list. Prefer that over a permanent collection. Fill website with that exhibition's own page on the venue's domain, not the venue homepage. Do not refuse it as a search. The same goes for one named artist, performer or company and their latest, current or next show: pick the one still open (or next upcoming), preferring one in or near home, and title it as its host venue does.",
    "Fill 'website' with the official homepage of the event or place (the venue's own site — never an aggregator, social media, Reddit, or a maps link). If you used web search and its results name or link the official site, use that; leave null only when no official site turns up.",
  ];
  if (text) parts.push(`User's saved input:\n${text}`);
  if (pageText) parts.push(`Fetched page content from ${url}:\n${pageText}`);
  if (post) {
    const platform = post.platform === "tiktok" ? "TikTok" : "Instagram";
    parts.push(
      [
        `The link is a ${platform} post${post.author ? ` by @${post.author}` : ""}.`,
        post.caption ? `Its caption:\n${post.caption}` : "It has no readable caption.",
        cover
          ? "Its cover image is attached — read any on-screen text (venue names, dates, addresses)."
          : "",
        "Identify the specific place or event the post is about — the venue or exhibition itself, not the account posting about it. Posts often mention several places; pick the one the post is mainly about, or the first named.",
        "Then use the web search tool to verify it and fill in the details, especially the official website.",
      ].filter(Boolean).join(" "),
    );
  }
  if (mapsLink) {
    parts.push(
      [
        `The link is a Google Maps pin${mapsLink.name ? ` for "${mapsLink.name}"` : ""}${
          mapsLink.lat !== null ? ` at ${mapsLink.lat},${mapsLink.lng}` : ""
        }.`,
        `There is no page content to read. Identify this place from its name${home.locality ? ` and your own knowledge of ${home.locality}` : ""}: fill in kind (almost always 'place'), area, category, and a one-line summary of what it is.`,
        "Use the web search tool to find this exact place's official website and fill 'website' — the app fetches its photo from there, so a maps save without it stays pictureless.",
        mapsLink.lat === null
          ? "Also search for the place's exact street address so it can be geocoded — the pin coordinates could not be extracted from the link."
          : "",
        "Only leave fields null if you genuinely don't recognise the place; still never invent prices or dates.",
      ].filter(Boolean).join(" "),
    );
  } else if (useWebSearch && !post) {
    parts.push(
      [
        url
          ? `The page at ${url} could not be read (blocked or unreachable).`
          : "There is no linked page to read.",
        `Use the web search tool to identify this exact event or place — search with ${
          url ? "the names from the URL slug" : "the names you can see in the input"
        }${home.locality ? ` plus "${home.locality}"` : ""} — and fill in verified details, especially start/end dates, venue, and price.`,
        `An event named without a date means the run that's on now or its next date: search for upcoming dates, and never save one that ended before today (${today}) — if only past dates turn up, leave the dates null.`,
        "If they asked for the current or latest exhibition at a named venue, open that venue's own homepage or what's-on / ongoing-exhibitions list (not a listings site). Pick the most recently opened special exhibition still open today if they said 'latest' or 'newest', otherwise the first special exhibition on that list. Confirm the official exhibition page is live and the dates include today; fill website with that page. Save the show (kind 'event'), not the venue as a place and not a postponed, cancelled, or closed one. If they named an artist or performer rather than a venue, find that show on its host venue's own site the same way.",
        url ? "" : "There is no link to save, so find this exact event's or place's own page for 'link'.",
        input.image_base64 ? "Combine that with what the screenshot shows." : "",
        "Also find the official website and fill 'website' — the app fetches the thumbnail photo from it.",
        "If search doesn't confirm a detail, leave it null; never guess.",
      ].filter(Boolean).join(" "),
    );
  }

  const content: Anthropic.ContentBlockParam[] = [];
  if (input.image_base64) {
    content.push({
      type: "image",
      source: {
        type: "base64",
        media_type: (input.image_media_type ?? "image/jpeg") as "image/jpeg",
        data: input.image_base64,
      },
    });
  } else if (cover) {
    content.push({
      type: "image",
      source: {
        type: "base64",
        media_type: cover.mediaType as "image/jpeg",
        data: cover.base64,
      },
    });
  }
  content.push({ type: "text", text: parts.join("\n\n") });

  const response = await anthropic.messages.create({
    // Sonnet whenever search is on: opus + web search blows past the edge
    // worker's 150s wall-clock budget (same lesson as the locate function).
    // Plain page reads stay on opus — no search rounds, so they're quick.
    model: useWebSearch ? "claude-sonnet-5" : "claude-opus-4-8",
    max_tokens: 4096,
    output_config: { format: { type: "json_schema", schema: cardSchema(home) } },
    ...(useWebSearch
      ? {
          tools: [
            { type: "web_search_20250305" as const, name: "web_search" as const, max_uses: 3 },
          ],
        }
      : {}),
    messages: [{ role: "user", content }],
  });

  // With web search the model may emit commentary text between searches —
  // the structured JSON is always the final text block.
  const textBlock = [...response.content].reverse().find((b) => b.type === "text");
  if (!textBlock || textBlock.type !== "text") {
    throw new Error("No structured output returned");
  }
  const { is_specific, link: proposedLink, ...card } = JSON.parse(textBlock.text) as ModelCard;
  card.category = normaliseCategory(card.kind, card.category);
  const seen = new Set<string>();
  for (const block of response.content) {
    if (block.type !== "web_search_tool_result" || !Array.isArray(block.content)) continue;
    for (const result of block.content) {
      const key = linkKey(result.url);
      if (key) seen.add(key);
    }
  }

  // The pin in a Maps URL is exact — trust it over geocoding the name.
  const pin = mapsLink && mapsLink.lat !== null && mapsLink.lng !== null
    ? { lat: mapsLink.lat, lng: mapsLink.lng }
    : null;
  let coords: { lat: number; lng: number } | null = pin;
  // Google knows the street address of nearly every place, where the
  // model's is a best guess from search snippets. A match replaces it.
  let google: PlaceMatch | null = card.kind === "place"
    ? await findPlace(mapsLink?.name ?? card.title, card, home, pin)
    : null;
  if (google) {
    card.address = google.address ?? card.address;
    if (!coords && google.lat != null && google.lng != null) {
      coords = { lat: google.lat, lng: google.lng };
    }
  }
  // Street addresses geocode far more reliably than small-venue names
  // (Nominatim rarely knows independent restaurants), so try those first.
  if (!coords && card.address) {
    coords = await geocodeNearHome(geocode, card.address, home);
  }
  if (!coords && (card.venue || card.area)) {
    coords = await geocodeNearHome(
      geocode,
      [card.venue ?? card.title, card.area].filter(Boolean).join(", "),
      home,
    );
  }
  // An event at a venue nothing else could place: ask Google for the venue.
  if (!coords && card.kind === "event" && card.venue) {
    google = await findPlace(card.venue, card, home, null, { samePostcode: true });
    if (google?.lat != null && google.lng != null) {
      coords = { lat: google.lat, lng: google.lng };
      card.address ??= google.address;
    }
  }

  // A card with nothing to stand on is not a save. The model's own verdict
  // comes first; the structural check catches the times it said "specific"
  // but still produced a spot with no link, no site, no pin and no address.
  if (is_specific === false || !isAnchored(card, { url, coords })) {
    throw new VagueInputError();
  }

  // Thumbnail: whatever the saved page offered (og:image, JSON-LD, or
  // its largest content picture). If that's still empty, try the official
  // website the model named — Reddit tips, blocked ticketing pages, maps
  // pins, and bare typed names all get a real venue photo this way.
  // The save's link: a pasted one as is; for typed names and screenshots,
  // the thing's own page, so the save opens somewhere and "Fetch again"
  // reads a page instead of searching from scratch.
  const eventDates = card.kind === "event"
    ? [card.starts_on, card.ends_on].filter((d): d is string => Boolean(d))
    : [];
  const own = !url && proposedLink ? await ownPage(proposedLink, seen, eventDates) : null;
  const savedUrl = url ?? own?.url ?? null;

  let imageUrl = page?.ogImage ??
    (own?.html ? heroImageFromHtml(own.html, own.url) : null);
  const ownTried = !url && proposedLink ? linkKey(proposedLink) : null;
  if (
    !imageUrl && card.website && isFetchable(card.website) &&
    !isMapsUrl(card.website) && card.website !== url &&
    (ownTried === null || linkKey(card.website) !== ownTried)
  ) {
    imageUrl = await heroImageFromUrl(card.website);
  }
  // The generic Google Maps app icon once poisoned several saves with
  // rainbow-streak thumbnails — never let any maps-branded asset through.
  if (imageUrl && /(?:gstatic|googleusercontent)\.com.*maps|maps_\d+dp\.(?:png|webp)/i.test(imageUrl)) {
    imageUrl = null;
  }
  // Named festivals and museums often have a Wikipedia photo when the
  // listing page is a JS shell or the save had no URL at all. Short or
  // generic names never reach this (see wikipediaQueries).
  if (!imageUrl) {
    for (const query of wikipediaQueries(card)) {
      imageUrl = await wikipediaImage(query);
      if (imageUrl) break;
    }
  }

  // Last resort: the place's own photo on Google.
  let googlePhoto: string | null = null;
  if (!imageUrl && google?.photo) {
    imageUrl = await placePhotoLink(google.id, google.credit);
    googlePhoto = await photoUri(google.photo, 400);
  }

  let color = await colorPromise.catch(() => null);
  if (!color && googlePhoto) {
    color = await colorFromImageUrl(googlePhoto).catch(() => null);
  } else if (!color && imageUrl) {
    color = await colorFromImageUrl(imageUrl).catch(() => null);
  }

  return {
    ...card,
    url: savedUrl,
    source: input.image_base64 ? "image" : url ? "link" : "text",
    lat: coords?.lat ?? null,
    lng: coords?.lng ?? null,
    color,
    image_url: imageUrl,
  };
}