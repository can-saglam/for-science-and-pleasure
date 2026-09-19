// Starters: the three chips on the first-run's save page. Pure helpers
// here (key, freshness, shaping the model's answer); the function does
// the fetching and caching.

export interface Starter {
  title: string;
  url: string;
  kind: "event" | "place";
}

export const STARTER_TTL_DAYS = 14;
export const STARTER_COUNT = 3;

/** Cache key: one row per city, however it was typed. */
export function starterKey(locality: string, country: string): string {
  const norm = (s: string) => s.trim().replace(/\s+/g, " ").toLowerCase();
  return `${norm(locality)}|${norm(country)}`;
}

export function starterFresh(fetchedAt: string | Date, now = new Date()): boolean {
  const t = typeof fetchedAt === "string" ? new Date(fetchedAt) : fetchedAt;
  return now.getTime() - t.getTime() < STARTER_TTL_DAYS * 86_400_000;
}

/// Hosts that are never a venue's own page. A starter must be something
/// the parser can read into a real card; a listings page yields a card
/// about the listings site.
const AGGREGATOR_RE =
  /(^|\.)(tripadvisor|timeout|yelp|eventbrite|ticketmaster|dice\.fm|ra\.co|songkick|google|facebook|instagram|tiktok|wikipedia|booking|opentable|thefork|resy|viator|getyourguide|designmynight|skiddle|seetickets|axs|lonelyplanet|culturetrip|secretldn|londonist|visitlondon|visit[a-z]+)\.(com|co\.uk|org|net|fm|co|de|fr|es|it|pt|nl)$/i;

/** Tidy the model's answer: https only, no aggregators, no duplicates, exactly the count. */
export function shapeStarters(raw: unknown): Starter[] {
  const list = Array.isArray((raw as { starters?: unknown })?.starters)
    ? (raw as { starters: unknown[] }).starters
    : [];
  const out: Starter[] = [];
  const seen = new Set<string>();
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    const title = typeof e.title === "string" ? e.title.trim() : "";
    const kind = e.kind === "event" ? "event" : "place";
    let url: URL;
    try {
      url = new URL(String(e.url ?? "").trim());
    } catch {
      continue;
    }
    if (!title || title.length > 48) continue;
    if (url.protocol !== "https:" && url.protocol !== "http:") continue;
    url.protocol = "https:";
    if (AGGREGATOR_RE.test(url.hostname)) continue;
    const host = url.hostname.replace(/^www\./, "");
    if (seen.has(host)) continue;
    seen.add(host);
    out.push({ title, url: url.toString(), kind });
    if (out.length === STARTER_COUNT) break;
  }
  return out;
}
