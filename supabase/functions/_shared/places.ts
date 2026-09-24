// Google Places (New): the last resort for a place's street address, pin
// and photo, after the page, the official site, Wikipedia and Nominatim.
//
// Google's terms let us keep a place ID indefinitely but not its photos,
// so a Google thumbnail is stored as a link to our own place-photo
// function, which asks Google for a fresh photo each time a phone first
// loads it. That link carries the photographer's name, which the detail
// view has to show. It is signed so the function can't be used to run
// arbitrary lookups on this key.
//
// Everything here is best-effort: no key, a quota hit or a miss all
// return null and the save carries on as before.
import type { Home } from "./home.ts";
import { namesCity } from "./home.ts";

const API = "https://places.googleapis.com/v1";

function apiKey(): string | null {
  return Deno.env.get("GOOGLE_MAPS_API_KEY") || null;
}

export interface PlaceMatch {
  id: string;
  name: string;
  address: string | null;
  lat: number | null;
  lng: number | null;
  /** The first photo's resource name, fresh from this search. */
  photo: string | null;
  /** Who took that photo, as Google credits them. */
  credit: string | null;
}

interface SearchPlace {
  id?: string;
  displayName?: { text?: string };
  formattedAddress?: string;
  location?: { latitude?: number; longitude?: number };
  photos?: { name?: string; authorAttributions?: { displayName?: string }[] }[];
}

// Words that say what kind of place it is rather than which one: "The
// Barbican Centre" and "Barbican" are the same place.
const FILLER = new Set([
  "the", "a", "an", "and", "of", "at", "in", "on", "de", "la", "le", "el", "il",
  "restaurant", "cafe", "bar", "pub", "bakery", "kitchen", "shop", "store",
  "gallery", "museum", "centre", "center", "house", "ltd", "limited", "co",
]);

function tokens(name: string): string[] {
  return name
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => (t.length > 1 || /\d/.test(t)) && !FILLER.has(t));
}

/**
 * Is Google's name for a place the one the user saved? One name inside
 * the other ("Dishoom" / "Dishoom Covent Garden"), or every word of the
 * shorter name in the longer (one in four may differ for long names).
 * "Tate Modern" and "Tate Britain" share a word but aren't the same place.
 * Which branch it is comes from the query and the pin, not from here.
 */
export function sameName(saved: string, found: string): boolean {
  const a = tokens(saved);
  const b = tokens(found);
  if (a.length === 0 || b.length === 0) return false;
  const squash = (t: string[]) => t.join("");
  if (squash(a).includes(squash(b)) || squash(b).includes(squash(a))) return true;
  const setB = new Set(b);
  const shorter = Math.min(a.length, b.length);
  const shared = a.filter((t) => setB.has(t)).length;
  return shared / shorter >= (shorter <= 3 ? 1 : 0.75);
}

/** Metres between two points; plenty accurate at city scale. */
export function metresBetween(
  a: { lat: number; lng: number },
  b: { lat: number; lng: number },
): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
}

/**
 * The search text: the name plus whatever narrows it to one branch. A
 * street address beats an area; a bare name gets the home city, unless
 * what we know already names somewhere else.
 */
export function placeQuery(
  name: string,
  hint: { address?: string | null; area?: string | null },
  home: Home,
): string {
  const where = hint.address ?? hint.area ?? null;
  const parts = [name, where];
  if (home.locality && !(where && namesCity(where, home))) parts.push(home.locality);
  return parts.filter(Boolean).join(", ");
}

/**
 * The one Google place this save is about, or null. `pin` is a Maps link's
 * exact coordinates: the match has to sit within a few hundred metres of
 * it. Without a pin the search leans towards home, unless the hint
 * already says it's elsewhere.
 */
export async function findPlace(
  name: string,
  hint: { address?: string | null; area?: string | null },
  home: Home,
  pin: { lat: number; lng: number } | null = null,
): Promise<PlaceMatch | null> {
  const key = apiKey();
  if (!key || !name.trim()) return null;

  const where = hint.address ?? hint.area ?? null;
  const awayFromHome = Boolean(where && home.locality && namesCity(where, home) &&
    !where.toLowerCase().includes(home.locality.toLowerCase()));
  const centre = pin ?? (home.lat != null && home.lng != null && !awayFromHome
    ? { lat: home.lat, lng: home.lng }
    : null);

  try {
    const res = await fetch(`${API}/places:searchText`, {
      method: "POST",
      signal: AbortSignal.timeout(8_000),
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask":
          "places.id,places.displayName,places.formattedAddress,places.location,places.photos",
      },
      body: JSON.stringify({
        textQuery: placeQuery(name, hint, home),
        pageSize: 3,
        languageCode: "en",
        ...(centre
          ? {
            locationBias: {
              circle: {
                center: { latitude: centre.lat, longitude: centre.lng },
                radius: pin ? 500 : 50_000,
              },
            },
          }
          : {}),
      }),
    });
    if (!res.ok) {
      console.warn("places search", res.status, (await res.text()).slice(0, 200));
      return null;
    }
    const { places = [] } = await res.json() as { places?: SearchPlace[] };
    for (const p of places) {
      const found = p.displayName?.text ?? "";
      if (!p.id || !sameName(name, found)) continue;
      const lat = p.location?.latitude ?? null;
      const lng = p.location?.longitude ?? null;
      if (pin && (lat == null || lng == null || metresBetween(pin, { lat, lng }) > 400)) continue;
      const photo = p.photos?.find((ph) => ph.name) ?? null;
      return {
        id: p.id,
        name: found,
        address: p.formattedAddress ?? null,
        lat,
        lng,
        photo: photo?.name ?? null,
        credit: photo?.authorAttributions?.[0]?.displayName ?? null,
      };
    }
    return null;
  } catch (e) {
    console.warn("places search failed", String(e));
    return null;
  }
}

/** A short-lived direct link to a photo, for reading its colour. */
export async function photoUri(photoName: string, maxWidth = 1200): Promise<string | null> {
  const key = apiKey();
  if (!key) return null;
  try {
    const res = await fetch(
      `${API}/${photoName}/media?maxWidthPx=${maxWidth}&skipHttpRedirect=true`,
      { headers: { "X-Goog-Api-Key": key }, signal: AbortSignal.timeout(8_000) },
    );
    if (!res.ok) return null;
    const { photoUri } = await res.json() as { photoUri?: string };
    return photoUri ?? null;
  } catch {
    return null;
  }
}

/** The first photo of a place, looked up afresh from its ID. */
export async function freshPhotoUri(placeId: string): Promise<string | null> {
  const key = apiKey();
  if (!key) return null;
  try {
    const res = await fetch(`${API}/places/${encodeURIComponent(placeId)}`, {
      headers: { "X-Goog-Api-Key": key, "X-Goog-FieldMask": "photos" },
      signal: AbortSignal.timeout(8_000),
    });
    if (!res.ok) return null;
    const { photos = [] } = await res.json() as { photos?: { name?: string }[] };
    const name = photos.find((p) => p.name)?.name;
    return name ? await photoUri(name) : null;
  } catch {
    return null;
  }
}

async function hmac(value: string): Promise<string> {
  const secret = apiKey() ?? "";
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(`place-photo:${secret}`),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)));
  return [...mac.slice(0, 12)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The thumbnail link stored on the item: our function, signed, credited. */
export async function placePhotoLink(placeId: string, credit: string | null): Promise<string> {
  const base = Deno.env.get("SUPABASE_URL") ?? "";
  const query = [`p=${encodeURIComponent(placeId)}`, `s=${await hmac(placeId)}`];
  if (credit) query.push(`by=${encodeURIComponent(credit)}`);
  return `${base}/functions/v1/place-photo?${query.join("&")}`;
}

export async function validPlacePhotoSignature(placeId: string, sig: string): Promise<boolean> {
  if (!placeId || !sig || !apiKey()) return false;
  const expected = await hmac(placeId);
  if (expected.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}
