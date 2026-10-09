// Suggestions: a pool of real things in a home city for the add page, the
// empty library tabs and the first-save page. Both are picked from the
// city's guides (Time Out, The Infatuation…) by a web search, but link to
// the thing's own site. Events are checked the way a save's link is (the
// page loads and dates this run); a place's site has to answer. Pure
// helpers first, then the two refreshes.
import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import { cleanLink, linkKey, ownPage } from "./extract.ts";
import { publicFetch } from "./netguard.ts";
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

/// The add page shows two events a day in a new order each day, so a
/// bigger event pool goes longer before it repeats; places barely change.
export const POOL_SIZE: Record<SuggestionKind, number> = { event: 14, place: 8 };
/// Places change slowly. Events weekly, or every three days in a city
/// with enough people to notice the same ones coming round.
const TTL_DAYS: Record<SuggestionKind, number> = { event: 7, place: 30 };
const BUSY_EVENT_TTL_DAYS = 3;
export const BUSY_CITY_PEOPLE = 20;
/// A refresh that never finished (the worker died) stops blocking the next.
const REFRESH_LEASE_MS = 5 * 60_000;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

/// Stale by age, or thinned out by events ending: under three left and a
/// day since the last try.
export function isDue(
  fetchedAt: string | null,
  kind: SuggestionKind,
  live: number,
  now = new Date(),
  busy = false,
): boolean {
  if (!fetchedAt) return true;
  const age = now.getTime() - new Date(fetchedAt).getTime();
  const ttl = kind === "event" && busy ? BUSY_EVENT_TTL_DAYS : TTL_DAYS[kind];
  return age >= ttl * 86_400_000 || (live < 3 && age >= 86_400_000);
}

/// Only an event pool between the busy and the normal age needs to know
/// whether its city is busy.
export function busyMatters(fetchedAt: string | null, kind: SuggestionKind, now = new Date()): boolean {
  if (kind !== "event" || !fetchedAt) return false;
  const age = now.getTime() - new Date(fetchedAt).getTime();
  return age >= BUSY_EVENT_TTL_DAYS * 86_400_000 && age < TTL_DAYS.event * 86_400_000;
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

/// A club night, supper club or pop-up often has no page but its ticket
/// page: one event's page on Dice or Resident Advisor counts as its own.
export function isTicketEventPage(url: string): boolean {
  const u = new URL(url);
  const host = u.hostname.replace(/^www\./, "");
  return (host === "dice.fm" && /^\/event\/[^/]+\/?$/.test(u.pathname)) ||
    (host === "ra.co" && /^\/events\/\d+\/?$/.test(u.pathname));
}

/// Tidy the model's list: official https pages only, no listings sites,
/// real dates on events (ended ones dropped), no duplicates, pool-sized.
export function shapeSuggestions(raw: unknown, kind: SuggestionKind, today: string, cap = POOL_SIZE[kind]): Suggestion[] {
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
    if (AGGREGATOR_RE.test(host) && !(kind === "event" && isTicketEventPage(url))) continue;
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
    if (out.length >= cap) break;
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
/// or, for a site that walls off servers (no html), in the link itself or
/// the title the search showed it under.
export function aboutEvent(title: string, html: string | null, url: string, shown?: string): boolean {
  let telling = words(title).filter((w) => !TITLE_FILLER.has(w));
  if (telling.length === 0) telling = words(title);
  if (telling.length === 0) return false;
  let where = words(decodeURIComponent(new URL(url).pathname)).join(" ");
  if (!html && shown) where += " " + words(shown).join(" ");
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

/// What a refresh's model calls used, for suggestion_runs.
export interface Usage {
  model: string;
  input_tokens: number;
  output_tokens: number;
  searches: number;
}

export interface Refreshed {
  items: Suggestion[];
  proposed: number;
  usage: Usage;
}

const SUGGEST_MODEL = "claude-sonnet-5";

function usageOf(response: { usage?: { input_tokens?: number; output_tokens?: number; server_tool_use?: { web_search_requests?: number } | null } }): Usage {
  return {
    model: SUGGEST_MODEL,
    input_tokens: response.usage?.input_tokens ?? 0,
    output_tokens: response.usage?.output_tokens ?? 0,
    searches: response.usage?.server_tool_use?.web_search_requests ?? 0,
  };
}

export function addUsage(a: Usage, b: Usage): Usage {
  return {
    model: a.model,
    input_tokens: a.input_tokens + b.input_tokens,
    output_tokens: a.output_tokens + b.output_tokens,
    searches: a.searches + b.searches,
  };
}

/// Where the picks come from. Each city has its own best-read guides, so
/// these are examples, not a list to stick to.
const GUIDES =
  "the city's best-read guides and critics' picks — Time Out, The Infatuation, Eater, Resident Advisor, " +
  "Condé Nast Traveller, the local press's critics, or whatever plays that part locally";

/// Narrower searches side by side: one long search for ten ran out of
/// output before it answered. Each stays well inside the worker's wall
/// clock, and one coming back empty doesn't sink the others.
const EVENT_FOCUSES = [
  "exhibitions, theatre and film seasons",
  "gigs, festivals, talks and markets",
  "food and drink events, supper clubs, pop-ups, comedy and club nights",
];

async function searchEvents(
  anthropic: Anthropic,
  focus: string,
  locality: string,
  country: string,
  today: string,
): Promise<{ raw: unknown[]; seen: [string, string][]; note: string; usage: Usage }> {
  const response = await anthropic.messages.create({
    model: SUGGEST_MODEL,
    // 8192 cut answers off mid-list after three searches' worth of reading.
    max_tokens: 16_384,
    output_config: { format: { type: "json_schema", schema: EVENT_SCHEMA } },
    // One or two searches of the guides, then the picks' own pages.
    tools: [{ type: "web_search_20250305" as const, name: "web_search" as const, max_uses: 4 }],
    messages: [{
      role: "user",
      content:
        `Today is ${today}. Find 6 ${focus} in ${locality}, ${country} that are on now or open in the next six weeks, ` +
        `worth going to with a friend: the interesting, new and talked-about, not tourist staples. ` +
        `Start from what editors pick: first search ${GUIDES}. ` +
        `No permanent collections, tours or chains, and nothing that ends before today. ` +
        `Guides are where you find them, not what you return: the url must be that one event's own page on the ` +
        `venue's or organiser's site, the kind of address that names the event (e.g. a venue's /whats-on/<event-name> page), ` +
        `or, for a club night, gig, supper club or pop-up that has no such page, its single event page on Dice ` +
        `(dice.fm/event/…) or Resident Advisor (ra.co/events/…). Never a what's-on listing, a round-up, another ` +
        `ticketing, news or guide site, and only a url you saw in the search results, so search for the picks' own pages. Search at most four times, then answer straight away with the JSON: no commentary.`,
    }],
  });
  const seen: [string, string][] = [];
  for (const block of response.content) {
    if (block.type !== "web_search_tool_result" || !Array.isArray(block.content)) continue;
    for (const result of block.content) {
      const key = linkKey(result.url);
      if (key) seen.push([key, result.title ?? ""]);
    }
  }
  const text = answerText(response.content);
  const raw = readItems(text);
  return {
    raw: raw ?? [],
    seen,
    note: raw ? `${raw.length} (${response.stop_reason})` : `unreadable (${response.stop_reason}): ${text.slice(0, 120)}`,
    usage: usageOf(response),
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
  // Every link the searches showed, with the title they showed it under.
  const seen = new Map<string, string>();
  const notes: string[] = [];
  let usage: Usage = { model: SUGGEST_MODEL, input_tokens: 0, output_tokens: 0, searches: 0 };
  for (const s of searches) {
    if (s.status === "fulfilled") {
      lists.push(s.value.raw);
      s.value.seen.forEach(([k, title]) => seen.set(k, title));
      notes.push(s.value.note);
      usage = addUsage(usage, s.value.usage);
    } else {
      notes.push(`failed: ${String(s.reason).slice(0, 120)}`);
    }
  }
  // Every candidate is checked, and the cap applies to what passes.
  const shaped = shapeSuggestions({ items: interleave(lists) }, "event", today, Infinity);
  await stage(`searches: ${notes.join(" / ")}; checking ${shaped.length} links`);
  const vouched = new Set(seen.keys());
  const checked = await Promise.all(shaped.map(async (s) => {
    const own = await ownPage(s.url, vouched, [s.starts_on, s.ends_on].filter((d): d is string => !!d));
    if (!own) return null;
    const shown = seen.get(linkKey(s.url) ?? "");
    return aboutEvent(s.title, own.html, own.url, shown) ? { ...s, url: own.url } : null;
  }));
  return {
    items: checked.filter((s): s is Suggestion => s !== null).slice(0, POOL_SIZE.event),
    proposed: shaped.length,
    usage,
  };
}

/// Alternate the lists so the pool's cap doesn't cut one kind.
export function interleave(lists: unknown[][]): unknown[] {
  return Array.from({ length: Math.max(0, ...lists.map((l) => l.length)) })
    .flatMap((_, i) => lists.map((l) => l[i]).filter((x) => x !== undefined));
}

const PLACE_FOCUSES = [
  "restaurants, cafés, bakeries and bars",
  "galleries, cinemas, bookshops and music venues",
];

async function searchPlaces(
  anthropic: Anthropic,
  focus: string,
  locality: string,
  country: string,
): Promise<{ raw: unknown[]; usage: Usage }> {
  const response = await anthropic.messages.create({
    model: SUGGEST_MODEL,
    max_tokens: 8_192,
    output_config: { format: { type: "json_schema", schema: PLACE_SCHEMA } },
    tools: [{ type: "web_search_20250305" as const, name: "web_search" as const, max_uses: 3 }],
    messages: [{
      role: "user",
      content:
        `Find 6 ${focus} in ${locality}, ${country} worth going to with a friend: the interesting ones critics and locals rate, ` +
        `new openings and long-loved favourites, not famous landmarks or chains. Start from what editors pick: search ${GUIDES}. ` +
        `Guides are where you find them, not what you return: each url must be the place's own official https website — ` +
        `never a guide, google, maps, tripadvisor, instagram, facebook, a booking site or a tourism portal; leave out a place ` +
        `without its own site. Search at most three times, then answer straight away with the JSON: no commentary.`,
    }],
  });
  return { raw: readItems(answerText(response.content)) ?? [], usage: usageOf(response) };
}

/// Places worth going to, picked from the city's guides by a web search.
/// `quick` is a brand-new city's first ask, which waits on the answer:
/// the model's own knowledge, in seconds, until the searched pool lands.
/// A site that doesn't resolve drops.
export async function refreshPlaces(locality: string, country: string, today: string, quick = false): Promise<Refreshed> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  if (quick) return await knownPlaces(anthropic, locality, country, today);
  const searches = await Promise.allSettled(
    PLACE_FOCUSES.map((focus) => searchPlaces(anthropic, focus, locality, country)),
  );
  const lists: unknown[][] = [];
  let usage: Usage = { model: SUGGEST_MODEL, input_tokens: 0, output_tokens: 0, searches: 0 };
  for (const s of searches) {
    if (s.status !== "fulfilled") continue;
    lists.push(s.value.raw);
    usage = addUsage(usage, s.value.usage);
  }
  const shaped = shapeSuggestions({ items: interleave(lists) }, "place", today, Infinity);
  const alive = await Promise.all(shaped.map(async (s) => (await resolves(s.url)) ? s : null));
  return {
    items: alive.filter((s): s is Suggestion => s !== null).slice(0, POOL_SIZE.place),
    proposed: shaped.length,
    usage,
  };
}

async function knownPlaces(anthropic: Anthropic, locality: string, country: string, today: string): Promise<Refreshed> {
  const response = await anthropic.messages.create({
    model: SUGGEST_MODEL,
    max_tokens: 2048,
    output_config: { format: { type: "json_schema", schema: PLACE_SCHEMA } },
    messages: [{
      role: "user",
      content:
        `Name ${POOL_SIZE.place + 2} real places in ${locality}, ${country} worth going to with a friend: ` +
        `about half restaurants, cafés and bars, half galleries, museums, cinemas and music venues. ` +
        `Loved by locals, not only the famous landmarks. Each url MUST be that place's own official https website, ` +
        `a domain you are sure exists — never google, maps, tripadvisor, timeout, wikipedia, instagram, facebook or a tourism portal. ` +
        `If you are unsure of a domain, pick a place whose official site you are sure of.`,
    }],
  });
  const shaped = shapeSuggestions({ items: readItems(answerText(response.content)) ?? [] }, "place", today);
  const alive = await Promise.all(shaped.map(async (s) => (await resolves(s.url)) ? s : null));
  return { items: alive.filter((s): s is Suggestion => s !== null), proposed: shaped.length, usage: usageOf(response) };
}

/// The site answers at all. Bot walls (403, 429, 503) count as alive; a
/// dead domain or a 404 doesn't.
async function resolves(url: string): Promise<boolean> {
  try {
    const res = await publicFetch(url, {
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
