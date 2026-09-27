// Suggestions: a pool of real things in a home city for the empty library
// tabs and the first-save page. Events come from a web search and are
// checked the way a save's link is (the page loads and dates this run);
// places come from the model's knowledge, official sites only. Pure
// helpers first, then the two refreshes.
import Anthropic from "npm:@anthropic-ai/sdk";
import { cleanLink, linkKey, ownPage } from "./extract.ts";
import { AGGREGATOR_RE } from "./starters.ts";

export type SuggestionKind = "event" | "place";

export interface Suggestion {
  title: string;
  url: string;
  kind: SuggestionKind;
  venue: string | null;
  starts_on: string | null;
  ends_on: string | null;
}

export const POOL_SIZE = 8;
const TTL_DAYS: Record<SuggestionKind, number> = { event: 7, place: 14 };
/// A refresh that never finished (the worker died) stops blocking the next.
const REFRESH_LEASE_MS = 5 * 60_000;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

/// Stale by age, or thinned out by events ending: under three left and a
/// day since the last try.
export function isDue(fetchedAt: string | null, kind: SuggestionKind, live: number, now = new Date()): boolean {
  if (!fetchedAt) return true;
  const age = now.getTime() - new Date(fetchedAt).getTime();
  return age >= TTL_DAYS[kind] * 86_400_000 || (live < 3 && age >= 86_400_000);
}

export function leaseFree(refreshingSince: string | null, now = new Date()): boolean {
  return !refreshingSince || now.getTime() - new Date(refreshingSince).getTime() > REFRESH_LEASE_MS;
}

/// An event is on until its last day; a place always is.
export function stillOn(s: Suggestion, today: string): boolean {
  if (s.kind === "place") return true;
  const last = s.ends_on ?? s.starts_on;
  return !!last && last >= today;
}

/// Tidy the model's list: official https pages only, no listings sites,
/// real dates on events (ended ones dropped), no duplicates, pool-sized.
export function shapeSuggestions(raw: unknown, kind: SuggestionKind, today: string): Suggestion[] {
  const list = Array.isArray((raw as { items?: unknown })?.items) ? (raw as { items: unknown[] }).items : [];
  const out: Suggestion[] = [];
  const seen = new Set<string>();
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    const title = typeof e.title === "string" ? e.title.trim() : "";
    const url = typeof e.url === "string" ? cleanLink(e.url.trim().replace(/^http:/, "https:")) : null;
    if (!title || title.length > 60 || !url) continue;
    const host = new URL(url).hostname;
    if (AGGREGATOR_RE.test(host)) continue;
    // Places are one per site; events can share a venue's site.
    const key = kind === "place" ? host.replace(/^www\./, "") : linkKey(url);
    if (!key || seen.has(key)) continue;
    const venue = typeof e.venue === "string" && e.venue.trim() ? e.venue.trim() : null;
    let starts: string | null = null;
    let ends: string | null = null;
    if (kind === "event") {
      starts = typeof e.starts_on === "string" && ISO_DAY.test(e.starts_on) ? e.starts_on : null;
      ends = typeof e.ends_on === "string" && ISO_DAY.test(e.ends_on) ? e.ends_on : null;
      if (!starts) continue;
      if (ends && ends < starts) ends = null;
    }
    const suggestion: Suggestion = { title, url, kind, venue, starts_on: starts, ends_on: ends };
    if (!stillOn(suggestion, today)) continue;
    seen.add(key);
    out.push(suggestion);
    if (out.length === POOL_SIZE) break;
  }
  return out;
}

const TITLE_FILLER = new Set([
  "the", "and", "for", "with", "from", "at", "of", "in", "on", "a", "an", "to", "live", "tour",
  "festival", "exhibition", "show", "presents", "london",
]);

function words(s: string): string[] {
  return s
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((w) => w.length > 1);
}

/// Is this page about the event, not a listing that mentions it? Most of
/// the title's telling words must be in the page's own title or headline,
/// or, for a site that walls off servers (no html), in the link itself.
export function aboutEvent(title: string, html: string | null, url: string): boolean {
  let telling = words(title).filter((w) => !TITLE_FILLER.has(w));
  if (telling.length === 0) telling = words(title);
  if (telling.length === 0) return false;
  let where = words(decodeURIComponent(new URL(url).pathname)).join(" ");
  if (html) {
    const heads = [
      html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1],
      html.match(/<meta[^>]+property=["']og:title["'][^>]*content=["']([^"']*)["']/i)?.[1],
      html.match(/<meta[^>]+content=["']([^"']*)["'][^>]*property=["']og:title["']/i)?.[1],
      html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i)?.[1]?.replace(/<[^>]+>/g, " "),
    ];
    where += " " + words(heads.filter(Boolean).join(" ").replace(/&[a-z#0-9]+;/gi, " ")).join(" ");
  }
  const have = new Set(where.split(" "));
  const hits = telling.filter((w) => have.has(w)).length;
  return hits >= Math.ceil(telling.length / 2);
}

/// The stored pool as the app gets it: ended events gone.
export function servePool(payload: unknown, kind: SuggestionKind, today: string): Suggestion[] {
  const items = Array.isArray((payload as { items?: unknown })?.items) ? (payload as { items: Suggestion[] }).items : [];
  return items.filter((s) => s && s.kind === kind && typeof s.url === "string" && stillOn(s, today));
}

// MARK: - Refreshing

const EVENT_SCHEMA = {
  type: "object",
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "The event's name as its organiser or venue lists it, never with the venue or dates appended" },
          venue: { type: ["string", "null"], description: "The venue's short name" },
          starts_on: { type: "string", description: "First day, yyyy-MM-dd" },
          ends_on: { type: ["string", "null"], description: "Last day of a run, yyyy-MM-dd; null for a one-night event" },
          url: { type: "string", description: "The event's own page on the venue's or organiser's site, exactly as seen in the search results" },
        },
        required: ["title", "venue", "starts_on", "ends_on", "url"],
        additionalProperties: false,
      },
    },
  },
  required: ["items"],
  additionalProperties: false,
} as const;

const PLACE_SCHEMA = {
  type: "object",
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "The place's own short name, in the local spelling" },
          venue: { type: ["string", "null"], description: "The neighbourhood" },
          url: { type: "string", description: "The place's own official https website" },
        },
        required: ["title", "venue", "url"],
        additionalProperties: false,
      },
    },
  },
  required: ["items"],
  additionalProperties: false,
} as const;

/// The structured answer. With search on, it can arrive split across
/// several text blocks (citations break it up) after the last search, and
/// commentary can come before it.
export function answerText(content: ReadonlyArray<{ type: string; text?: string }>): string {
  let lastTool = -1;
  content.forEach((b, i) => {
    if (b.type !== "text") lastTool = i;
  });
  return content
    .slice(lastTool + 1)
    .filter((b) => b.type === "text" && b.text)
    .map((b) => b.text)
    .join("")
    .trim();
}

export function readItems(text: string): unknown[] | null {
  const attempt = (s: string) => {
    try {
      const parsed = JSON.parse(s);
      return Array.isArray(parsed?.items) ? parsed.items as unknown[] : null;
    } catch {
      return null;
    }
  };
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  return attempt(text) ?? (start >= 0 && end > start ? attempt(text.slice(start, end + 1)) : null);
}

export interface Refreshed {
  items: Suggestion[];
  proposed: number;
}

/// Two narrower searches side by side: one long search for ten ran out
/// of output before it answered. Each stays well inside the worker's wall
/// clock, and one coming back empty doesn't sink the other.
const EVENT_FOCUSES = [
  "exhibitions, theatre and film seasons",
  "gigs, festivals, talks and markets",
];

async function searchEvents(
  anthropic: Anthropic,
  focus: string,
  locality: string,
  country: string,
  today: string,
): Promise<{ raw: unknown[]; seen: string[]; note: string }> {
  const response = await anthropic.messages.create({
    model: "claude-sonnet-5",
    max_tokens: 8192,
    output_config: { format: { type: "json_schema", schema: EVENT_SCHEMA } },
    tools: [{ type: "web_search_20250305" as const, name: "web_search" as const, max_uses: 3 }],
    messages: [{
      role: "user",
      content:
        `Today is ${today}. Find 6 ${focus} in ${locality}, ${country} that are on now or open in the next six weeks, ` +
        `worth going to with a friend. Prefer what critics and locals rate over tourist staples; no permanent collections, ` +
        `tours or chains, and nothing that ends before today. For each, the url must be that one event's own page on the ` +
        `venue's or organiser's site, the kind of address that names the event (e.g. a venue's /whats-on/<event-name> page) — ` +
        `never a what's-on listing, a round-up, a ticketing, news or guide site — and only a url you saw in the search results. ` +
        `Search venues' own sites. Search at most three times, then answer straight away with the JSON: no commentary.`,
    }],
  });
  const seen: string[] = [];
  for (const block of response.content) {
    if (block.type !== "web_search_tool_result" || !Array.isArray(block.content)) continue;
    for (const result of block.content) {
      const key = linkKey(result.url);
      if (key) seen.push(key);
    }
  }
  const text = answerText(response.content);
  const raw = readItems(text);
  return {
    raw: raw ?? [],
    seen,
    note: raw ? `${raw.length} (${response.stop_reason})` : `unreadable (${response.stop_reason}): ${text.slice(0, 120)}`,
  };
}

/// What's on now or soon, from a web search. Every link is opened: a page
/// that's gone, or that dates another year's run, drops the event.
export async function refreshEvents(
  locality: string,
  country: string,
  today: string,
  stage: (note: string) => unknown = () => {},
): Promise<Refreshed> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const searches = await Promise.allSettled(
    EVENT_FOCUSES.map((focus) => searchEvents(anthropic, focus, locality, country, today)),
  );
  const lists: unknown[][] = [];
  const seen = new Set<string>();
  const notes: string[] = [];
  for (const s of searches) {
    if (s.status === "fulfilled") {
      lists.push(s.value.raw);
      s.value.seen.forEach((k) => seen.add(k));
      notes.push(s.value.note);
    } else {
      notes.push(`failed: ${String(s.reason).slice(0, 120)}`);
    }
  }
  // Alternate the two lists so the pool's cap doesn't cut one kind.
  const raw = Array.from({ length: Math.max(0, ...lists.map((l) => l.length)) })
    .flatMap((_, i) => lists.map((l) => l[i]).filter((x) => x !== undefined));
  const shaped = shapeSuggestions({ items: raw }, "event", today);
  await stage(`searches: ${notes.join(" / ")}; checking ${shaped.length} links`);
  const checked = await Promise.all(shaped.map(async (s) => {
    const own = await ownPage(s.url, seen, [s.starts_on, s.ends_on].filter((d): d is string => !!d));
    return own && aboutEvent(s.title, own.html, own.url) ? { ...s, url: own.url } : null;
  }));
  return { items: checked.filter((s): s is Suggestion => s !== null), proposed: shaped.length };
}

/// Places worth going to, from the model's knowledge: quick, and famous
/// official sites are what it knows best. A site that doesn't resolve drops.
export async function refreshPlaces(locality: string, country: string, today: string): Promise<Refreshed> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const response = await anthropic.messages.create({
    model: "claude-sonnet-5",
    max_tokens: 2048,
    output_config: { format: { type: "json_schema", schema: PLACE_SCHEMA } },
    messages: [{
      role: "user",
      content:
        `Name ${POOL_SIZE + 2} real places in ${locality}, ${country} worth going to with a friend: ` +
        `about half restaurants, cafés and bars, half galleries, museums, cinemas and music venues. ` +
        `Loved by locals, not only the famous landmarks. Each url MUST be that place's own official https website, ` +
        `a domain you are sure exists — never google, maps, tripadvisor, timeout, wikipedia, instagram, facebook or a tourism portal. ` +
        `If you are unsure of a domain, pick a place whose official site you are sure of.`,
    }],
  });
  const shaped = shapeSuggestions({ items: readItems(answerText(response.content)) ?? [] }, "place", today);
  const alive = await Promise.all(shaped.map(async (s) => (await resolves(s.url)) ? s : null));
  return { items: alive.filter((s): s is Suggestion => s !== null), proposed: shaped.length };
}

/// The site answers at all. Bot walls (403, 429, 503) count as alive; a
/// dead domain or a 404 doesn't.
async function resolves(url: string): Promise<boolean> {
  try {
    const res = await fetch(url, {
      redirect: "follow",
      signal: AbortSignal.timeout(8_000),
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
      },
    });
    await res.body?.cancel();
    return res.status < 400 || [403, 429, 503].includes(res.status);
  } catch {
    return false;
  }
}
