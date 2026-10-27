// Suggestions: a pool of real things in a home city for the add page, the
// empty library tabs and the first-save page. Both are picked from the
// city's guides (Time Out, The Infatuation…) by a web search, but link to
// the thing's own site. Events are checked the way a save's link is (the
// page loads and dates this run); a place's site has to answer. Pure
// helpers first, then the two refreshes.
import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import { EVENT_CATEGORIES, normaliseCategory, PLACE_CATEGORIES } from "./categories.ts";
import { colorFromImageUrl, heroImageFromUrl } from "./color.ts";
import { cleanLink, type extractCard, linkKey, ownPage } from "./extract.ts";
import type { Home } from "./home.ts";
import { publicFetch } from "./netguard.ts";
import { findPlace, isVenue, type PlaceMatch, photoUri, placePhotoLink } from "./places.ts";
import { AGGREGATOR_RE } from "./starters.ts";

export type SuggestionKind = "event" | "place";

/// A pick's full card, the same as a lookup of its link returns, stored
/// with the pick so tapping it needs no lookup of its own.
export type PickCard = Awaited<ReturnType<typeof extractCard>>;

export interface Suggestion {
  title: string;
  url: string;
  kind: SuggestionKind;
  venue: string | null;
  starts_on: string | null;
  ends_on: string | null;
  /** What a friend would call it, when the title is long; null when not. */
  short_title?: string | null;
  /** exhibition, restaurant, and the rest of that kind's vocabulary.
   * Missing on picks stored before the chip said what they are. */
  category?: string | null;
  /** One line on what it is and why go, under the chip's when and where.
   * Missing on picks stored before chips had one; null when none came. */
  about?: string | null;
  /** The chip's picture: an event page's image, a place's photo link.
   * Missing on picks stored before pictures; null once tried. */
  image?: string | null;
  /** The picture's dominant colour, for the chip's tint. */
  color?: string | null;
  /** An event whose page gave no picture has had its venue looked up on
   * Google for one. Missing until then. */
  venue_photo?: boolean;
  /** The full card a tap saves. Missing until looked up (see pick_cards.ts);
   * null when a lookup couldn't pin it, so a tap looks it up instead. */
  card?: PickCard | null;
}

/// The add page shows two events a day in a new order each day, so a
/// bigger event pool goes longer before it repeats; places barely change.
export const POOL_SIZE: Record<SuggestionKind, number> = { event: 14, place: 8 };
/// Fewer events than this and a refresh searches once more, and a pool
/// thinned below it by events ending is due again the next day.
export const MIN_EVENTS = 5;
/// Places change slowly. Events weekly, or every three days in a city
/// with enough people to notice the same ones coming round.
const TTL_DAYS: Record<SuggestionKind, number> = { event: 7, place: 30 };
const BUSY_EVENT_TTL_DAYS = 3;
export const BUSY_CITY_PEOPLE = 20;
/// A refresh that never finished (the worker died) stops blocking the next.
const REFRESH_LEASE_MS = 5 * 60_000;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

/// Stale by age, or thin: under three left (under MIN_EVENTS for events)
/// and a day since the last try.
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
  const thin = live < (kind === "event" ? MIN_EVENTS : 3);
  return age >= ttl * 86_400_000 || (thin && age >= 86_400_000);
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

/// A refresh that found nothing or failed leaves the pool as overdue as it
/// was, so without this every visit after the lease would pay for another
/// search; one try a day is enough.
export function triedRecently(last: { outcome: string; at: string } | null, now = new Date()): boolean {
  return !!last && last.outcome !== "kept" && now.getTime() - new Date(last.at).getTime() < 86_400_000;
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
    const short = typeof e.short_title === "string" ? e.short_title.trim() : "";
    const shortTitle = short && short.length <= 30 && short.length < title.length ? short : null;
    const category = normaliseCategory(kind, typeof e.category === "string" ? e.category : null);
    const about = cleanAbout(e.about);
    const suggestion: Suggestion = {
      title,
      url,
      kind,
      venue,
      starts_on: starts,
      ends_on: ends,
      ...(shortTitle ? { short_title: shortTitle } : {}),
      ...(category ? { category } : {}),
      ...(about ? { about } : {}),
    };
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
  return items
    .filter((s) => s && s.kind === kind && typeof s.url === "string" && stillOn(s, today))
    .map(withCardPhoto);
}

/// A page that turns robots away leaves the chip without a picture, though
/// the card a tap saves found one (often the venue's, from Wikipedia).
/// The chip wears that rather than a bare ticket.
export function withCardPhoto(s: Suggestion): Suggestion {
  if (s.image !== null || !s.card?.image_url) return s;
  return { ...s, image: s.card.image_url, color: s.color ?? s.card.color ?? null };
}

/// Never looked at for a picture, or an event with none yet whose venue
/// hasn't been tried.
export function needsPicture(s: Suggestion): boolean {
  if (s.image === undefined) return true;
  return s.kind === "event" && !s.image && !s.card?.image_url && namedVenue(s.venue) !== null &&
    s.venue_photo === undefined;
}

/// A pool with picks still to be looked at for a picture.
export function undressed(items: Suggestion[]): boolean {
  return items.some(needsPicture);
}

/// What the phone is sent: only picks with a picture. A chip is a photo
/// and a line or two; without the photo it reads as broken. Picks still
/// being dressed join once they have one (`pictures_coming`).
export function forPhone(items: Suggestion[]): Suggestion[] {
  return items.filter((s) => typeof s.image === "string" && s.image.length > 0);
}

/// A venue worth finding on a map: not "Various venues", "Online", "TBA".
export function namedVenue(venue: string | null | undefined): string | null {
  const v = venue?.trim();
  if (!v || v.length < 3) return null;
  if (/^(various|multiple|several|online|virtual|tba|tbc|secret|across|all over)\b/i.test(v)) return null;
  return v;
}

/// A pool stored before the chip named what each pick is.
export function unlabelled(items: Suggestion[]): boolean {
  return items.some((s) => s.category === undefined);
}

/// Write categories from a labelling answer onto the picks that lack one.
/// An unreadable answer leaves them unlabelled, so the next ask tries again.
/// A pick the answer skipped becomes "other" rather than being asked forever.
export function applyCategories(items: Suggestion[], labeled: unknown): Suggestion[] {
  const list = Array.isArray(labeled) ? labeled : [];
  const byUrl = new Map<string, string>();
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    if (typeof e.url !== "string" || typeof e.category !== "string") continue;
    byUrl.set(e.url, e.category);
  }
  if (byUrl.size === 0) return items;
  return items.map((s) => {
    if (s.category !== undefined) return s;
    return { ...s, category: normaliseCategory(s.kind, byUrl.get(s.url)) ?? "other" };
  });
}

/// A place's card from its Google match, shaped as a lookup's would be.
/// Null without a pin: a card that can't go on the map isn't worth keeping.
export function placeCard(s: Suggestion, match: PlaceMatch, image: string | null, color: string | null): PickCard | null {
  if (match.lat == null || match.lng == null) return null;
  return {
    kind: "place",
    title: s.title,
    summary: s.about ?? null,
    venue: null,
    area: s.venue,
    address: match.address,
    category: s.category ?? null,
    price: null,
    booking_url: null,
    starts_on: null,
    ends_on: null,
    website: s.url,
    showings: null,
    url: s.url,
    source: "link",
    lat: match.lat,
    lng: match.lng,
    color,
    image_url: image,
    place_id: isVenue(match) ? match.id : null,
    page_unread: false,
  };
}

/// The chip has room for two short lines, about a hundred characters;
/// anything longer would be cut off mid-thought, and goes.
const ABOUT_MAX = 110;

export function cleanAbout(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const about = raw.replace(/\s+/g, " ").trim();
  return about && about.length <= ABOUT_MAX ? about : null;
}

/// Never described, or described before the line had a limit. One that
/// comes back too long again is dropped to null, so it's asked once.
function needsAbout(s: Suggestion): boolean {
  return s.about === undefined || (typeof s.about === "string" && s.about.length > ABOUT_MAX);
}

/// A pool stored before chips said what each pick is like.
export function undescribed(items: Suggestion[]): boolean {
  return items.some(needsAbout);
}

/// Write lines from a describing answer onto the picks that lack one. An
/// unreadable answer leaves them as they were, so the next ask tries
/// again; a pick the answer skipped gets null rather than being asked
/// forever.
export function applyAbouts(items: Suggestion[], described: unknown): Suggestion[] {
  const list = Array.isArray(described) ? described : [];
  const byUrl = new Map<string, string>();
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    const about = cleanAbout(e.about);
    if (typeof e.url !== "string" || !about) continue;
    byUrl.set(e.url, about);
  }
  if (list.length === 0) return items;
  return items.map((s) => needsAbout(s) ? { ...s, about: byUrl.get(s.url) ?? null } : s);
}

const ABOUT_HINT =
  "One short sentence, under 80 characters, on what it is and why it's worth going, the way a friend would put it, " +
  "in the spirit of \"tiny wine bar with a short, brilliant small-plates menu\" but in your own words. " +
  "Don't repeat the name, dates, prices or address, and only say what you're sure is true.";

/// Each pick's picture and card colour, for the chips: an event's page
/// image, or a place's Google photo as the same signed link saved places
/// keep. Best-effort; a pick that's been tried keeps `image: null`, so a
/// pool is only ever dressed once. With `withinMs`, a pick still being
/// looked at when time's up goes as it was, to be dressed later.
export async function dress(
  items: Suggestion[],
  locality: string,
  country: string,
  withinMs?: number,
): Promise<Suggestion[]> {
  const home: Home = { locality, country, timezone: "UTC", lat: null, lng: null };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeUp = withinMs === undefined
    ? null
    : new Promise<null>((done) => timer = setTimeout(() => done(null), withinMs));
  try {
    return await Promise.all(items.map(async (s): Promise<Suggestion> => {
      if (!needsPicture(s)) return s;
      const dressed = dressOne(s, home);
      return (timeUp ? await Promise.race([dressed, timeUp]) : await dressed) ?? s;
    }));
  } finally {
    clearTimeout(timer);
  }
}

async function dressOne(s: Suggestion, home: Home): Promise<Suggestion> {
  try {
    if (s.kind === "event") {
      if (s.image === undefined) {
        const image = await heroImageFromUrl(s.url);
        if (image) return { ...s, image, color: await colorFromImageUrl(image) };
      }
      const fromCard = withCardPhoto({ ...s, image: null, color: s.color ?? null });
      if (fromCard.image) return fromCard;
      return await venuePhoto(fromCard, home);
    }
    // The search for its photo also finds its address, pin and Google
    // place, which is all a place's card needs: kept, at no extra cost.
    const match = await findPlace(s.title, { area: s.venue }, home);
    if (!match) return { ...s, image: null, color: null };
    if (!match.photo) return { ...s, image: null, color: null, card: placeCard(s, match, null, null) };
    const [image, direct] = await Promise.all([placePhotoLink(match.id, match.credit), photoUri(match.photo, 400)]);
    const color = direct ? await colorFromImageUrl(direct) : null;
    return { ...s, image, color, card: placeCard(s, match, image, color) };
  } catch {
    return { ...s, image: null, color: null };
  }
}

/// A page that turns robots away (Resident Advisor, Cloudflare) leaves an
/// event bare; the venue's Google photo stands in, as a place's does.
async function venuePhoto(s: Suggestion, home: Home): Promise<Suggestion> {
  const venue = namedVenue(s.venue);
  if (!venue) return { ...s, venue_photo: true };
  const match = await findPlace(venue, { area: home.locality }, home);
  if (!match?.photo) return { ...s, venue_photo: true };
  const [image, direct] = await Promise.all([placePhotoLink(match.id, match.credit), photoUri(match.photo, 400)]);
  const color = direct ? await colorFromImageUrl(direct) : null;
  return { ...s, image, color: s.color ?? color, venue_photo: true };
}

/// Name the picks a pool stored before categories: one short call, no
/// search. A miss leaves them unlabelled so the next ask tries again.
export async function label(items: Suggestion[]): Promise<Suggestion[]> {
  const pending = items.filter((s) => s.category === undefined);
  if (pending.length === 0) return items;
  const kind = pending[0].kind;
  const vocab = kind === "place" ? PLACE_CATEGORIES : EVENT_CATEGORIES;
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const response = await anthropic.messages.create({
    model: SUGGEST_MODEL,
    max_tokens: 1024,
    output_config: { format: { type: "json_schema", schema: labelSchema(kind) } },
    messages: [{
      role: "user",
      content:
        `Label each ${kind} with one category from: ${vocab.join(", ")}. ` +
        `exhibition is a dated show; a gallery or museum building is gallery or museum, never exhibition. ` +
        `cafe is a café or bakery; drink is a bar. Use each url unchanged.\n` +
        pending.map((s) => [s.url, s.title, s.venue].filter(Boolean).join("\t")).join("\n"),
    }],
  });
  const parsed = readItems(answerText(response.content));
  return parsed ? applyCategories(items, parsed) : items;
}

/// A line for each pick in a pool stored before chips had one: one short
/// call, no search. A miss leaves them as they were so the next ask tries
/// again.
export async function describe(items: Suggestion[]): Promise<Suggestion[]> {
  const pending = items.filter(needsAbout);
  if (pending.length === 0) return items;
  const kind = pending[0].kind;
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const response = await anthropic.messages.create({
    model: SUGGEST_MODEL,
    max_tokens: 2048,
    output_config: { format: { type: "json_schema", schema: DESCRIBE_SCHEMA } },
    messages: [{
      role: "user",
      content:
        `For each ${kind} below (url, name, ${kind === "event" ? "venue, dates" : "neighbourhood"}, category), write ${ABOUT_HINT} ` +
        `If you don't know it, say plainly what kind of ${kind} it is. Use each url unchanged.\n` +
        pending.map((s) =>
          [s.url, s.title, s.venue, s.kind === "event" ? [s.starts_on, s.ends_on].filter(Boolean).join("–") : null, s.category]
            .filter(Boolean).join("\t")
        ).join("\n"),
    }],
  });
  const parsed = readItems(answerText(response.content));
  return parsed ? applyAbouts(items, parsed) : items;
}

const DESCRIBE_SCHEMA = {
  type: "object",
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          url: { type: "string" },
          about: { type: "string" },
        },
        required: ["url", "about"],
        additionalProperties: false,
      },
    },
  },
  required: ["items"],
  additionalProperties: false,
} as const;

function labelSchema(kind: SuggestionKind) {
  const vocab = kind === "place" ? PLACE_CATEGORIES : EVENT_CATEGORIES;
  return {
    type: "object",
    properties: {
      items: {
        type: "array",
        items: {
          type: "object",
          properties: {
            url: { type: "string" },
            category: { type: "string", enum: [...vocab] },
          },
          required: ["url", "category"],
          additionalProperties: false,
        },
      },
    },
    required: ["items"],
    additionalProperties: false,
  };
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
          short_title: {
            type: "string",
            description:
              "What a friend would call it, in at most 24 characters: 'Pitchfork Festival' for 'Pitchfork Music Festival London 2026', " +
              "'Monika Sosnowska' for \"Monika Sosnowska: 'Weight of Matter'\". The title itself when it's already that short",
          },
          venue: { type: ["string", "null"], description: "The venue's short name" },
          starts_on: { type: "string", description: "First day, yyyy-MM-dd" },
          ends_on: { type: ["string", "null"], description: "Last day of a run, yyyy-MM-dd; null for a one-night event" },
          url: { type: "string", description: "The event's own page on the venue's or organiser's site, exactly as seen in the search results" },
          category: {
            type: "string",
            enum: EVENT_CATEGORIES,
            description:
              "What is on. exhibition is a dated show, gig a concert, film a screening or season, " +
              "market a market, festival a festival. Never a place word such as gallery or restaurant.",
          },
          about: { type: "string", description: ABOUT_HINT },
        },
        required: ["title", "short_title", "venue", "starts_on", "ends_on", "url", "category", "about"],
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
          category: {
            type: "string",
            enum: PLACE_CATEGORIES,
            description:
              "What the place is. A gallery, museum or park is that, never exhibition. cafe is a café or bakery; drink is a bar.",
          },
          about: { type: "string", description: ABOUT_HINT },
        },
        required: ["title", "venue", "url", "category", "about"],
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
/// The one more search a short refresh makes, open to any kind.
const TOP_UP_FOCUS = "things on of any kind (exhibitions, theatre, film, gigs, talks, markets, food and drink)";

async function searchEvents(
  anthropic: Anthropic,
  focus: string,
  locality: string,
  country: string,
  today: string,
  avoid: string[] = [],
  count = 6,
): Promise<{ raw: unknown[]; seen: [string, string][]; note: string; usage: Usage }> {
  const others = avoid.length ? `Not these, already picked: ${avoid.join("; ")}. ` : "";
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
        `Today is ${today}. Find ${count} ${focus} in ${locality}, ${country} that are on now or open in the next six weeks, ` +
        `worth going to with a friend: the interesting, new and talked-about, not tourist staples. ${others}` +
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
  // Cut off after a last search, the list it had already written is
  // still in an earlier text block.
  const raw = readItems(text) ?? lastListIn(response.content);
  const usage = usageOf(response);
  return {
    raw: raw ?? [],
    seen,
    note: raw
      ? `${raw.length} (${response.stop_reason})`
      : `unreadable (${response.stop_reason}, ${usage.output_tokens} out; ${blockSummary(response.content)}): ${text.slice(0, 120)}`,
    usage,
  };
}

/// The last text block that holds a list, scanning back from the end.
export function lastListIn(content: ReadonlyArray<{ type: string; text?: string }>): unknown[] | null {
  for (let i = content.length - 1; i >= 0; i--) {
    const b = content[i];
    if (b.type !== "text" || !b.text) continue;
    const items = readItems(b.text);
    if (items?.length) return items;
  }
  return null;
}

/// "text×3 1.2k, server_tool_use×4, web_search_tool_result×4, thinking×2 9.8k":
/// where an answer's output went, for a note when it couldn't be read.
export function blockSummary(content: ReadonlyArray<{ type: string; text?: string; thinking?: string }>): string {
  const tally = new Map<string, { n: number; chars: number }>();
  for (const b of content) {
    const t = tally.get(b.type) ?? { n: 0, chars: 0 };
    t.n += 1;
    t.chars += (b.text ?? b.thinking ?? "").length;
    tally.set(b.type, t);
  }
  return [...tally].map(([type, { n, chars }]) =>
    `${type}×${n}${chars ? ` ${(chars / 1000).toFixed(1)}k` : ""}`
  ).join(", ");
}

/// What's on now or soon, from a web search. Every link is opened: a page
/// that's gone, or that dates another year's run, drops the event. The
/// last pool's events still on (`keep`) stay after the new ones, already
/// checked and dressed; under MIN_EVENTS, one more search tops it up.
export async function refreshEvents(
  locality: string,
  country: string,
  today: string,
  stage: (note: string) => unknown = () => {},
  keep: Suggestion[] = [],
): Promise<Refreshed> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  // Every link the searches showed, with the title they showed it under.
  const seen = new Map<string, string>();
  const notes: string[] = [];
  let usage: Usage = { model: SUGGEST_MODEL, input_tokens: 0, output_tokens: 0, searches: 0 };
  const gather = (searches: PromiseSettledResult<Awaited<ReturnType<typeof searchEvents>>>[]) => {
    const lists: unknown[][] = [];
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
    return shapeSuggestions({ items: interleave(lists) }, "event", today, Infinity);
  };
  // Every candidate is checked, and the cap applies to what passes.
  const check = async (shaped: Suggestion[]) => {
    const vouched = new Set(seen.keys());
    const checked = await Promise.all(shaped.map(async (s) => {
      const own = await ownPage(s.url, vouched, [s.starts_on, s.ends_on].filter((d): d is string => !!d));
      if (!own) return null;
      const shown = seen.get(linkKey(s.url) ?? "");
      return aboutEvent(s.title, own.html, own.url, shown) ? { ...s, url: own.url } : null;
    }));
    // One already in the pool stays as it is there: dressed, described,
    // carded.
    return checked.filter((s): s is Suggestion => s !== null).map((s) => keep.find((k) => samePick(k, s)) ?? s);
  };

  const shaped = gather(await Promise.allSettled(
    EVENT_FOCUSES.map((focus) => searchEvents(anthropic, focus, locality, country, today)),
  ));
  await stage(`searches: ${notes.join(" / ")}; checking ${shaped.length} links`);
  const found = await check(shaped);
  const kept = mergePicks([found, keep], today);
  let proposed = shaped.length;
  let topped: Suggestion[] = [];
  if (kept.length < MIN_EVENTS) {
    await stage(`searches: ${notes.join(" / ")}; ${found.length} new and ${kept.length - found.length} kept, topping up`);
    const more = gather(await Promise.allSettled([
      searchEvents(anthropic, TOP_UP_FOCUS, locality, country, today, kept.map((s) => s.title), 8),
    ]));
    proposed += more.length;
    topped = await check(more);
  }
  const items = mergePicks([found, topped, keep], today);
  await stage(
    `searches: ${notes.join(" / ")}; ${found.length + topped.length} new` +
      (topped.length ? ` (${topped.length} topping up)` : "") + `, ${items.length - found.length - topped.length} kept`,
  );
  return { items: items.slice(0, POOL_SIZE.event), proposed, usage };
}

/// One event, by its link or its name.
function samePick(a: Suggestion, b: Suggestion): boolean {
  return (linkKey(a.url) ?? a.url) === (linkKey(b.url) ?? b.url) ||
    a.title.trim().toLowerCase() === b.title.trim().toLowerCase();
}

/// Lists in order of preference, as one: each event once, and only while
/// it's on.
export function mergePicks(lists: Suggestion[][], today: string): Suggestion[] {
  const out: Suggestion[] = [];
  for (const s of lists.flat()) {
    if (stillOn(s, today) && !out.some((o) => samePick(o, s))) out.push(s);
  }
  return out;
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
