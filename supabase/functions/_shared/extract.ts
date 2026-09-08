import Anthropic from "npm:@anthropic-ai/sdk";
import { EVENT_CATEGORIES, normaliseCategory, PLACE_CATEGORIES } from "./categories.ts";
import {
  colorFromImageBytes,
  colorFromImageUrl,
  heroImageFromUrl,
  ogImageFromHtml,
} from "./color.ts";
import { corsHeaders, geocode, resolveMapsLink } from "./geo.ts";
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

// The schema carries the home in its examples (area, price, address), so
// it is built per call rather than once.
const cardSchema = (home: Home) => ({
  type: "object",
  properties: {
    kind: {
      type: "string",
      enum: ["event", "place"],
      description:
        "'event' if it has dates or a run (exhibition, gig, festival, pop-up); 'place' if it's evergreen (cafe, restaurant, bar, shop, park)",
    },
    title: { type: "string", description: "Short name of the event or place" },
    summary: {
      type: ["string", "null"],
      description: "One sentence on what it is and why it's interesting",
    },
    venue: { type: ["string", "null"], description: "Venue or institution name" },
    area: {
      type: ["string", "null"],
      description:
        `Neighbourhood or district within its city (for ${home.locality}, the kind of name a local would use, like 'Peckham' or 'South Bank' in London)`,
    },
    address: {
      type: ["string", "null"],
      description:
        `Street address. Include the city (and country) when it is not ${home.locality} — e.g. '12 Rue de Rivoli, Paris, France'`,
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
  },
  required: [
    "kind", "title", "summary", "venue", "area", "address",
    "category", "price", "booking_url", "starts_on", "ends_on", "website",
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
      ogImage: ogImageFromHtml(html, url),
    };
  } catch {
    return null;
  }
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
        `There is no page content to read. Identify this place from its name and your own knowledge of ${home.locality}: fill in kind (almost always 'place'), area, category, and a one-line summary of what it is.`,
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
        } plus "${home.locality}" — and fill in verified details, especially start/end dates, venue, and price.`,
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
  const card = JSON.parse(textBlock.text) as ParsedCard;
  card.category = normaliseCategory(card.kind, card.category);

  // The pin in a Maps URL is exact — trust it over geocoding the name.
  let coords: { lat: number; lng: number } | null =
    mapsLink && mapsLink.lat !== null && mapsLink.lng !== null
      ? { lat: mapsLink.lat, lng: mapsLink.lng }
      : null;
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

  // Thumbnail: the saved page's og:image when we have it; otherwise try the
  // official website the model named — Reddit tips, blocked ticketing pages,
  // maps pins, and bare typed names all get a real venue photo this way.
  let imageUrl = page?.ogImage ?? null;
  if (
    !imageUrl && card.website && isFetchable(card.website) &&
    !isMapsUrl(card.website) && card.website !== url
  ) {
    imageUrl = await heroImageFromUrl(card.website);
  }
  // The generic Google Maps app icon once poisoned several saves with
  // rainbow-streak thumbnails — never let any maps-branded asset through.
  if (imageUrl && /(?:gstatic|googleusercontent)\.com.*maps|maps_\d+dp\.(?:png|webp)/i.test(imageUrl)) {
    imageUrl = null;
  }

  let color = await colorPromise.catch(() => null);
  if (!color && imageUrl) {
    color = await colorFromImageUrl(imageUrl).catch(() => null);
  }

  return {
    ...card,
    url,
    source: input.image_base64 ? "image" : url ? "link" : "text",
    lat: coords?.lat ?? null,
    lng: coords?.lng ?? null,
    color,
    image_url: imageUrl,
  };
}