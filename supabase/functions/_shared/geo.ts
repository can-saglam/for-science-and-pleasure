// Small, dependency-free helpers shared by functions. Kept separate from
// extract.ts so that functions which only geocode (e.g. locate) don't pull in
// the imagescript dependency, whose native codec loading crashes the worker.
import { metresBetween } from "./places.ts";

// Free OpenStreetMap geocoding — used only server-side to attach coordinates
// so the app can do distance-based "nearby" suggestions and directions.
// Nominatim (openstreetmap.org) refuses Supabase's servers outright (403),
// so addresses go to Photon, which serves the same OpenStreetMap data, and
// bare UK postcodes to postcodes.io. Nominatim is only asked when Photon
// itself is down.
const GEO_UA = "CanWeGo/1.0 (https://canwego.app; geocoding)";
type LatLng = { lat: number; lng: number };

// Nominatim allows one request per second per app.
let lastNominatim = 0;
async function politely(): Promise<void> {
  const wait = lastNominatim + 1_100 - Date.now();
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastNominatim = Date.now();
}

function normAddress(s: string): string {
  const words = s
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .replace(/\brd\b/g, "road")
    .replace(/\bst\b/g, "street")
    .replace(/\bave\b/g, "avenue")
    .replace(/\bln\b/g, "lane")
    .replace(/\bsq\b/g, "square")
    .replace(/\s+/g, " ")
    .trim();
  return ` ${words} `;
}

export interface PhotonProps {
  name?: string;
  street?: string;
  type?: string;
}

/// Photon always answers with its nearest guess — "12 Rue de Rivoli,
/// London" comes back as a Piccadilly bar. A hit counts only when the
/// street it's on (or, for a street, district or town, its own name)
/// is in the address that was asked for.
export function photonMatches(props: PhotonProps, query: string): boolean {
  const q = normAddress(query);
  const named = (s?: string) => Boolean(s && normAddress(s).trim() && q.includes(normAddress(s)));
  return props.street ? named(props.street) : named(props.name);
}

/// `road` marks a hit that is a whole street rather than a door on it.
async function photon(
  query: string,
  near?: LatLng,
): Promise<(LatLng & { road: boolean }) | null | undefined> {
  const bias = near ? `&lat=${near.lat}&lon=${near.lng}` : "";
  try {
    const res = await fetch(
      `https://photon.komoot.io/api/?limit=5${bias}&q=${encodeURIComponent(query)}`,
      { headers: { "User-Agent": GEO_UA }, signal: AbortSignal.timeout(8_000) },
    );
    if (!res.ok) {
      await res.body?.cancel();
      console.warn("photon refused", res.status);
      return undefined;
    }
    const { features = [] } = await res.json() as {
      features?: { geometry?: { coordinates?: number[] }; properties?: PhotonProps }[];
    };
    for (const f of features) {
      const [lng, lat] = f.geometry?.coordinates ?? [];
      const props = f.properties ?? {};
      if (lat != null && lng != null && photonMatches(props, query)) {
        return { lat, lng, road: props.type === "street" };
      }
    }
    return null;
  } catch (e) {
    console.warn("photon failed", String(e));
    return undefined;
  }
}

async function nominatim(query: string): Promise<LatLng | null> {
  try {
    await politely();
    const res = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(query)}`,
      { headers: { "User-Agent": GEO_UA }, signal: AbortSignal.timeout(8_000) },
    );
    if (!res.ok) {
      await res.body?.cancel();
      console.warn("nominatim refused", res.status);
      return null;
    }
    const arr = await res.json();
    if (!arr?.[0]?.lat) return null;
    return { lat: parseFloat(arr[0].lat), lng: parseFloat(arr[0].lon) };
  } catch (e) {
    console.warn("nominatim failed", String(e));
    return null;
  }
}

async function ukPostcodeCentre(postcode: string): Promise<LatLng | null> {
  try {
    const res = await fetch(
      `https://api.postcodes.io/postcodes/${encodeURIComponent(postcode)}`,
      { headers: { "User-Agent": GEO_UA }, signal: AbortSignal.timeout(8_000) },
    );
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    const { result } = await res.json() as { result?: { latitude?: number; longitude?: number } };
    return result?.latitude != null && result.longitude != null
      ? { lat: result.latitude, lng: result.longitude }
      : null;
  } catch (e) {
    console.warn("postcodes.io failed", String(e));
    return null;
  }
}

const BARE_UK_POSTCODE_RE =
  /^\s*([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})\s*(?:,\s*(?:united kingdom|uk|gb|england|scotland|wales|northern ireland))?\s*$/i;
const UK_POSTCODE_RE = /\b([A-Z]{1,2}\d[A-Z\d]?)\s*(\d[A-Z]{2})\b/;

export async function geocode(query: string, near?: LatLng): Promise<LatLng | null> {
  const bare = query.match(BARE_UK_POSTCODE_RE)?.[1];
  if (bare) {
    const centre = await ukPostcodeCentre(bare);
    if (centre) return centre;
  }
  const found = await photon(query, near);
  const hit: LatLng | null = found === undefined
    ? await nominatim(query)
    : found && { lat: found.lat, lng: found.lng };
  // A full postcode pins an address to a few doors; a street match alone
  // can be the far end of a long road ("Cromwell Road, SW7 2RL" is the V&A,
  // not Earl's Court). The postcode wins over a whole-street hit, and over
  // any hit more than 300m from it.
  const pc = bare ? null : query.toUpperCase().match(UK_POSTCODE_RE);
  if (pc) {
    const centre = await ukPostcodeCentre(`${pc[1]} ${pc[2]}`);
    if (centre && (!hit || found?.road || metresBetween(hit, centre) > 300)) return centre;
  }
  return hit;
}

export interface MapsLinkInfo {
  name: string | null;
  lat: number | null;
  lng: number | null;
}

// Google Maps pages are tens of MB of JS and crash the worker if fetched, but
// the URL itself already carries the place name and pin coordinates.
export function parseGoogleMapsUrl(url: string): MapsLinkInfo | null {
  try {
    const u = new URL(url);
    const isMaps =
      (/(^|\.)google\.[a-z.]+$/.test(u.hostname) &&
        u.pathname.startsWith("/maps")) ||
      u.hostname === "maps.google.com";
    if (!isMaps) return null;
    const place = u.pathname.match(/\/place\/([^/]+)/)?.[1];
    const name = place
      ? decodeURIComponent(place.replace(/\+/g, " "))
      : u.searchParams.get("q");
    // !3d…!4d… is the pin itself; @lat,lng is just the viewport centre.
    const pin = url.match(/!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/);
    const at = url.match(/@(-?\d+\.\d+),(-?\d+\.\d+)/);
    const m = pin ?? at;
    return {
      name: name?.trim() || null,
      lat: m ? parseFloat(m[1]) : null,
      lng: m ? parseFloat(m[2]) : null,
    };
  } catch {
    return null;
  }
}

// Share-sheet links (maps.app.goo.gl) are opaque; follow the redirect to the
// full URL without reading the (huge) body, then parse that.
export async function resolveMapsLink(url: string): Promise<MapsLinkInfo | null> {
  const direct = parseGoogleMapsUrl(url);
  if (direct) return direct;
  try {
    const short = new URL(url);
    if (!/^(maps\.app\.goo\.gl|goo\.gl|g\.co)$/.test(short.hostname)) return null;
    // Short links now serve a client-side interstitial instead of an HTTP
    // redirect; _imcp=1 is what that page appends to force the real redirect.
    short.searchParams.set("_imcp", "1");
    const res = await fetch(short.toString(), {
      redirect: "follow",
      signal: AbortSignal.timeout(10_000),
      // Without a browser UA, Google serves bot pages instead of redirecting.
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Accept-Language": "en-GB,en;q=0.9",
      },
    });
    res.body?.cancel();
    let finalUrl = res.url;
    // UK/EU egress IPs get bounced to a consent interstitial; the real maps
    // URL (with the pin) rides along in the `continue` parameter.
    const parsed = new URL(finalUrl);
    if (parsed.hostname === "consent.google.com") {
      const cont = parsed.searchParams.get("continue");
      if (cont) finalUrl = cont;
    }
    return parseGoogleMapsUrl(finalUrl);
  } catch {
    return null;
  }
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-ingest-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
