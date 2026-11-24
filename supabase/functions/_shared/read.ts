// Reading what a save links to: cleaning links, fetching pages without
// tripping over bot walls, and the dates and pictures a page carries.

import { heroImageFromHtml } from "./color.ts";
import type { ParsedCard } from "./ask.ts";
import { PAGE_BYTES, publicFetch, readTextCapped } from "./netguard.ts";

/// Where a link ends up after its redirects, without the query. A share
/// link's path (reddit.com/r/london/s/faEXlfZiWe) names nothing; where it
/// lands (…/comments/1v7w92y/welsh_cafe_in_peckham) gives search a lead.
export async function landingUrl(url: string): Promise<string | null> {
  try {
    const res = await publicFetch(url, {
      redirect: "follow",
      signal: AbortSignal.timeout(5_000),
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
      },
    });
    await res.body?.cancel();
    const from = new URL(url), to = new URL(res.url || url);
    if (to.host === from.host && to.pathname === from.pathname) return null;
    return `${to.origin}${to.pathname}`;
  } catch {
    return null;
  }
}

const URL_RE = /https?:\/\/\S+/i;

export function firstUrl(text: string): string | null {
  const m = text.match(URL_RE);
  return m ? m[0].replace(/[)\],.]+$/, "") : null;
}

export function isFetchable(url: string): boolean {
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
export function isMapsUrl(url: string): boolean {
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

export function looksBlocked(pageText: string): boolean {
  // A page with next to no words (a share link's empty shell, a script-only
  // app) gives the model nothing; searching does better.
  if ((pageText.match(/[\p{L}\p{N}]+/gu)?.length ?? 0) < 6) return true;
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

/// An event as a page's JSON-LD describes it. Venues often print only
/// "Opens 7 November" and keep the closing day in the structured data,
/// which the page text drops along with every other script.
export interface LdEvent {
  name: string | null;
  start: string | null;
  end: string | null;
}

const LD_EVENT_TYPE_RE = /event|exhibition|festival/i;

function ldDay(value: unknown): string | null {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}/.test(value) ? value.slice(0, 10) : null;
}

function collectLdEvents(node: unknown, out: LdEvent[], depth = 0): void {
  if (!node || typeof node !== "object" || depth > 4 || out.length >= 12) return;
  if (Array.isArray(node)) {
    for (const entry of node) collectLdEvents(entry, out, depth + 1);
    return;
  }
  const obj = node as Record<string, unknown>;
  const types = [obj["@type"]].flat().filter((t): t is string => typeof t === "string");
  if (types.some((t) => LD_EVENT_TYPE_RE.test(t))) {
    const start = ldDay(obj.startDate);
    const end = ldDay(obj.endDate);
    if (start || end) {
      out.push({ name: typeof obj.name === "string" ? obj.name.trim() || null : null, start, end });
    }
  }
  for (const key of ["@graph", "itemListElement", "item", "subEvent"]) {
    collectLdEvents(obj[key], out, depth + 1);
  }
}

export function jsonLdEvents(html: string): LdEvent[] {
  const out: LdEvent[] = [];
  for (const block of html.matchAll(
    /<script\b[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi,
  )) {
    try {
      collectLdEvents(JSON.parse(block[1]), out);
    } catch {
      // malformed block — keep looking
    }
  }
  return out;
}

/// The closing day the page's structured data gives this card's run: an
/// event there opening the same day, with one end date between them. An
/// end the next day is a night running past midnight, not a two-day run.
export function ldClosing(
  events: LdEvent[],
  card: Pick<ParsedCard, "kind" | "starts_on">,
): string | null {
  const start = card.starts_on;
  if (card.kind !== "event" || !start) return null;
  const dayAfter = new Date(Date.parse(`${start}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
  const ends = new Set(
    events
      .filter((e) => e.start === start && e.end && e.end >= start && e.end !== dayAfter)
      .map((e) => e.end!),
  );
  return ends.size === 1 ? [...ends][0] : null;
}

function ldEventLines(events: LdEvent[]): string {
  if (!events.length) return "";
  const lines = events.map((e) =>
    `- ${e.name ?? "(unnamed)"}: starts ${e.start ?? "unknown"}, ends ${e.end ?? "unknown"}`
  );
  return `Event dates from the page's structured data (JSON-LD), which often has a closing date the visible text leaves out:\n${lines.join("\n")}`;
}

function isSiteRoot(url: string): boolean {
  return new URL(url).pathname.replace(/\/+$/, "") === "";
}

/// The model's `link`, kept only if it leads somewhere real: the page
/// loads, or the site walls off servers but search showed the model that
/// exact page. A dead or guessed deep link is dropped, never swapped for
/// the site's homepage — two shows at one venue would then share a link
/// and read as duplicates of each other.
export async function ownPage(
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
    const res = await publicFetch(clean, {
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
    const html = (await readTextCapped(res, PAGE_BYTES)).slice(0, 600_000);
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

/// A link's page as the model reads it, with what the thumbnail and
/// closing date come from.
export interface Page {
  text: string;
  ogImage: string | null;
  events: LdEvent[];
}

export async function fetchPage(url: string): Promise<Page | null> {
  try {
    const res = await publicFetch(url, {
      redirect: "follow",
      signal: AbortSignal.timeout(15_000),
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml",
      },
    });
    if (!res.ok) return null;
    return pageOf(await readTextCapped(res, PAGE_BYTES), res.url || url);
  } catch {
    return null;
  }
}

function pageOf(raw: string, pageUrl: string): Page {
  // Cap the HTML before running regexes over it — pathological pages
  // (Google Maps is ~20MB of JS) would blow the worker's CPU budget.
  const html = raw.slice(0, 600_000);
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
  const events = jsonLdEvents(html);
  return {
    text: [title, metas.join("\n"), ldEventLines(events), scriptedTimes(html), body].filter(Boolean).join("\n\n").slice(0, 30_000),
    events,
    // og:image first, then JSON-LD and the page's largest picture — the
    // same ladder the model's suggested website gets. Gallery and
    // festival sites often skip social meta tags entirely.
    ogImage: heroImageFromHtml(html, pageUrl),
  };
}

const SCRIPTED_TIME_RE =
  /\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,? \d{1,2}(?:st|nd|rd|th)? (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*,?(?: \d{4},?)? (?:at )?\d{1,2}[:.]\d{2}\b(?![:.]\d)/g;

/// Dates with times that a page keeps in its scripts. Ticketing sites (the
/// BFI's festival among them) draw the screening list from a data array,
/// and the tag-stripped body has the heading with nothing under it.
export function scriptedTimes(html: string): string {
  const seen = new Set<string>();
  for (const block of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
    for (const m of block[1].matchAll(SCRIPTED_TIME_RE)) seen.add(m[0]);
  }
  if (!seen.size) return "";
  return `Dates and times in the page's listing data:\n${[...seen].slice(0, 40).join("\n")}`;
}

/// The plain web page a save links to, if it has one. Maps pins and
/// social posts are read their own ways; short links may be pins.
export function pageLink(text: string): string | null {
  const url = firstUrl(text);
  if (!url || !isFetchable(url) || isMapsUrl(url)) return null;
  return /^(maps\.app\.goo\.gl|goo\.gl|g\.co)$/i.test(new URL(url).hostname) ? null : url;
}

/// The page as this server reads it; null behind an error or a bot wall.
export async function readPage(url: string): Promise<Page | null> {
  const page = await fetchPage(url);
  return page && !looksBlocked(page.text) ? page : null;
}

/// The page as the phone read it. Some sites (Cloudflare's checks) wall
/// off this server's IP but not a phone's.
export function pageFromHtml(html: string, url: string): Page | null {
  const page = pageOf(html, url);
  return looksBlocked(page.text) ? null : page;
}
