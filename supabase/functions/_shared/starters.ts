// Starters: the three chips on the first-run's save page. Pure helpers
// here (key, freshness, shaping, fallbacks); the function does the fetch.

export interface Starter {
  title: string;
  url: string;
  kind: "event" | "place";
}

export const STARTER_TTL_DAYS = 14;
export const STARTER_COUNT = 3;

/// Last-resort chips when the model is down or comes back empty. Official
/// pages the parser can read. City-states also match on country.
const FALLBACKS: Record<string, Starter[]> = {
  london: [
    { title: "Photographers' Gallery", url: "https://thephotographersgallery.org.uk/", kind: "place" },
    { title: "Sessions Arts Club", url: "https://sessionsartsclub.com/", kind: "place" },
    { title: "Roundhouse", url: "https://www.roundhouse.org.uk/", kind: "place" },
  ],
  singapore: [
    { title: "National Gallery", url: "https://www.nationalgallery.sg/", kind: "place" },
    { title: "Atlas", url: "https://www.atlasbar.sg/", kind: "place" },
    { title: "The Projector", url: "https://theprojector.sg/", kind: "place" },
  ],
  lisbon: [
    { title: "MAAT", url: "https://www.maat.pt/", kind: "place" },
    { title: "Cervejaria Ramiro", url: "https://www.cervejariaramiro.pt/", kind: "place" },
    { title: "Lux Frágil", url: "https://www.luxfragil.com/", kind: "place" },
  ],
  paris: [
    { title: "Musée d'Orsay", url: "https://www.musee-orsay.fr/", kind: "place" },
    { title: "Septime", url: "https://www.septime-charonne.fr/", kind: "place" },
    { title: "Centre Pompidou", url: "https://www.centrepompidou.fr/", kind: "place" },
  ],
  "new york": [
    { title: "MoMA", url: "https://www.moma.org/", kind: "place" },
    { title: "Katz's Delicatessen", url: "https://www.katzsdelicatessen.com/", kind: "place" },
    { title: "Film Forum", url: "https://www.filmforum.org/", kind: "place" },
  ],
  tokyo: [
    { title: "Mori Art Museum", url: "https://www.mori.art.museum/", kind: "place" },
    { title: "teamLab Planets", url: "https://www.teamlab.art/e/planets/", kind: "place" },
    { title: "Unit", url: "https://www.unit-tokyo.com/", kind: "place" },
  ],
  berlin: [
    { title: "Neue Nationalgalerie", url: "https://www.smb.museum/en/museums-institutions/neue-nationalgalerie/", kind: "place" },
    { title: "Konnopke's Imbiss", url: "https://www.konnopke.de/", kind: "place" },
    { title: "Babylon", url: "https://babylonberlin.eu/", kind: "place" },
  ],
  barcelona: [
    { title: "Fundació Miró", url: "https://www.fmirobcn.org/", kind: "place" },
    { title: "Cal Pep", url: "https://www.calpep.com/", kind: "place" },
    { title: "CCCB", url: "https://www.cccb.org/", kind: "place" },
  ],
  amsterdam: [
    { title: "Stedelijk", url: "https://www.stedelijk.nl/", kind: "place" },
    { title: "Foodhallen", url: "https://www.foodhallen.nl/", kind: "place" },
    { title: "Eye Filmmuseum", url: "https://www.eyefilm.nl/", kind: "place" },
  ],
  melbourne: [
    { title: "NGV", url: "https://www.ngv.vic.gov.au/", kind: "place" },
    { title: "Cumulus Inc", url: "https://www.cumulusinc.com.au/", kind: "place" },
    { title: "The Astor", url: "https://www.astortheatre.net.au/", kind: "place" },
  ],
  "hong kong": [
    { title: "M+", url: "https://www.mplus.org.hk/", kind: "place" },
    { title: "Yardbird", url: "https://www.yardbirdrestaurant.com/", kind: "place" },
    { title: "Broadway Cinematheque", url: "https://www.cinema.com.hk/", kind: "place" },
  ],
  "san francisco": [
    { title: "SFMOMA", url: "https://www.sfmoma.org/", kind: "place" },
    { title: "Zuni Café", url: "https://zunicafe.com/", kind: "place" },
    { title: "Roxie Theater", url: "https://roxie.com/", kind: "place" },
  ],
  sydney: [
    { title: "MCA", url: "https://www.mca.com.au/", kind: "place" },
    { title: "Icebergs", url: "https://www.idrb.com/", kind: "place" },
    { title: "Sydney Opera House", url: "https://www.sydneyoperahouse.com/", kind: "place" },
  ],
  "los angeles": [
    { title: "The Broad", url: "https://www.thebroad.org/", kind: "place" },
    { title: "République", url: "https://republiquela.com/", kind: "place" },
    { title: "New Beverly Cinema", url: "https://thenewbev.com/", kind: "place" },
  ],
  chicago: [
    { title: "Art Institute", url: "https://www.artic.edu/", kind: "place" },
    { title: "Au Cheval", url: "https://www.auchevalchicago.com/", kind: "place" },
    { title: "Music Box Theatre", url: "https://www.musicboxtheatre.com/", kind: "place" },
  ],
  madrid: [
    { title: "Reina Sofía", url: "https://www.museoreinasofia.es/", kind: "place" },
    { title: "Sobrino de Botín", url: "https://www.botin.es/", kind: "place" },
    { title: "Cine Doré", url: "https://www.filmotecanacional.es/", kind: "place" },
  ],
  rome: [
    { title: "Galleria Borghese", url: "https://www.colosseo.it/en/galleria-borghese/", kind: "place" },
    { title: "Armando al Pantheon", url: "https://www.armandoalpantheon.it/", kind: "place" },
    { title: "Casa del Cinema", url: "https://www.casadelcinema.it/", kind: "place" },
  ],
  dublin: [
    { title: "IMMA", url: "https://imma.ie/", kind: "place" },
    { title: "Kehoe's", url: "https://www.kehoesdublin.ie/", kind: "place" },
    { title: "Lighthouse Cinema", url: "https://www.lighthousecinema.ie/", kind: "place" },
  ],
  copenhagen: [
    { title: "SMK", url: "https://www.smk.dk/", kind: "place" },
    { title: "Noma", url: "https://noma.dk/", kind: "place" },
    { title: "Grand Teatret", url: "https://www.grandteatret.dk/", kind: "place" },
  ],
  toronto: [
    { title: "AGO", url: "https://ago.ca/", kind: "place" },
    { title: "St. Lawrence Market", url: "https://www.stlawrencemarket.com/", kind: "place" },
    { title: "TIFF Lightbox", url: "https://www.tiff.net/", kind: "place" },
  ],
};

const CITY_STATES = new Set(["singapore", "hong kong", "monaco"]);
const ALIASES: Record<string, string> = {
  "new york city": "new york",
  nyc: "new york",
  "republic of singapore": "singapore",
  "hong kong sar": "hong kong",
  "los angeles": "los angeles",
  la: "los angeles",
  "san francisco": "san francisco",
  sf: "san francisco",
  "ciudad de mexico": "mexico city",
  "mexico city": "mexico city",
};

function norm(s: string): string {
  return s.trim().replace(/\s+/g, " ").toLowerCase();
}

function fallbackKey(locality: string, country: string): string | undefined {
  const loc = ALIASES[norm(locality)] ?? norm(locality);
  const ctry = ALIASES[norm(country)] ?? norm(country);
  if (FALLBACKS[loc]) return loc;
  if (CITY_STATES.has(ctry) && FALLBACKS[ctry]) return ctry;
  return undefined;
}

/** Built-in chips for a city — used when the model yields nothing. */
export function fallbackStarters(locality: string, country: string): Starter[] {
  const key = fallbackKey(locality, country);
  return key ? FALLBACKS[key] ?? [] : [];
}

/** Model result, then curated city list, then a stale cache — never drop a good row. */
export function chooseStarters(
  shaped: Starter[],
  fallback: Starter[],
  stale: Starter[] = [],
): Starter[] {
  if (shaped.length > 0) return shaped;
  if (fallback.length > 0) return fallback;
  return stale;
}

/** The structured JSON is the last text block; search commentary comes first. */
export function readModelStarters(content: ReadonlyArray<{ type: string; text?: string }>): unknown {
  const textBlock = [...content].reverse().find((b) => b.type === "text" && b.text);
  const raw = textBlock?.text?.trim() ?? "";
  if (!raw) return { starters: [] };
  try {
    return JSON.parse(raw);
  } catch {
    const start = raw.indexOf("{");
    const end = raw.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(raw.slice(start, end + 1));
      } catch {
        /* fall through */
      }
    }
    return { starters: [] };
  }
}

/** Cache key: one row per city, however it was typed. */
export function starterKey(locality: string, country: string): string {
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
