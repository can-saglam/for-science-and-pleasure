import Anthropic from "npm:@anthropic-ai/sdk";

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
}

const CARD_SCHEMA = {
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
      description: "London neighbourhood or area, e.g. 'Peckham', 'South Bank', 'Shoreditch'",
    },
    address: { type: ["string", "null"] },
    category: {
      type: ["string", "null"],
      description:
        "One of: exhibition, gig, theatre, film, market, festival, food, drink, cafe, talk, workshop, outdoors, other",
    },
    price: { type: ["string", "null"], description: "e.g. 'Free', '£12', '£8–£15'" },
    booking_url: { type: ["string", "null"] },
    starts_on: {
      type: ["string", "null"],
      description: "Opening/start date as YYYY-MM-DD, null if unknown or a place",
    },
    ends_on: {
      type: ["string", "null"],
      description: "Closing/end date as YYYY-MM-DD; for a one-day event same as starts_on",
    },
  },
  required: [
    "kind", "title", "summary", "venue", "area", "address",
    "category", "price", "booking_url", "starts_on", "ends_on",
  ],
  additionalProperties: false,
} as const;

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

async function fetchPageText(url: string): Promise<string | null> {
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
    const html = await res.text();
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
    return [title, metas.join("\n"), body].join("\n\n").slice(0, 30_000);
  } catch {
    return null;
  }
}

// Free OSM geocoder — used only server-side to attach coordinates so the app
// can do distance-based "nearby" suggestions and Google Maps directions.
export async function geocode(query: string): Promise<{ lat: number; lng: number } | null> {
  try {
    const res = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(query)}`,
      {
        headers: { "User-Agent": "for-science-and-pleasure/1.0" },
        signal: AbortSignal.timeout(8_000),
      },
    );
    if (!res.ok) return null;
    const arr = await res.json();
    if (!arr?.[0]?.lat) return null;
    return { lat: parseFloat(arr[0].lat), lng: parseFloat(arr[0].lon) };
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
): Promise<ParsedCard & { url: string | null; source: string; lat: number | null; lng: number | null }> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

  const text = (input.text ?? "").trim();
  const url = text ? firstUrl(text) : null;
  let pageText: string | null = null;
  if (url && isFetchable(url)) {
    pageText = await fetchPageText(url);
  }

  const today = new Date().toISOString().slice(0, 10);
  const parts: string[] = [
    `Today's date is ${today}. Extract a structured card for a London events/places app.`,
    "Resolve relative or partial dates to absolute YYYY-MM-DD dates (if a month is named without a year, assume the next occurrence from today).",
    "If a field is genuinely unknown, use null — do not guess venues, prices, or dates.",
  ];
  if (text) parts.push(`User's saved input:\n${text}`);
  if (pageText) parts.push(`Fetched page content from ${url}:\n${pageText}`);
  if (url && !pageText) {
    parts.push(`The link ${url} could not be fetched (it may be Instagram or blocked). Extract what you can from the input text${input.image_base64 ? " and the screenshot" : ""}.`);
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
  }
  content.push({ type: "text", text: parts.join("\n\n") });

  const response = await anthropic.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 4096,
    output_config: { format: { type: "json_schema", schema: CARD_SCHEMA } },
    messages: [{ role: "user", content }],
  });

  const textBlock = response.content.find((b) => b.type === "text");
  if (!textBlock || textBlock.type !== "text") {
    throw new Error("No structured output returned");
  }
  const card = JSON.parse(textBlock.text) as ParsedCard;

  let coords: { lat: number; lng: number } | null = null;
  if (card.venue || card.area) {
    coords = await geocode(
      [card.venue ?? card.title, card.area, "London"].filter(Boolean).join(", "),
    );
  }

  return {
    ...card,
    url,
    source: input.image_base64 ? "image" : url ? "link" : "text",
    lat: coords?.lat ?? null,
    lng: coords?.lng ?? null,
  };
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-ingest-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
