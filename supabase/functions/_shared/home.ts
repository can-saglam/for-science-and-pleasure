// A group's home: the city its library is about. It does three jobs and
// nothing more (launch plan, Phase 1a): parsing context for the model and
// the geocoder, the clock that "today" is measured on, and the map's
// default. It never blocks or moves data — a Paris save from a London
// group stays in Paris.
//
// I/O-free apart from groupHome(), so the prompt and geocoder rules can be
// unit-tested.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { localClock, localDate } from "./schedule.ts";

export interface Home {
  locality: string;
  country: string;
  timezone: string;
  lat: number | null;
  lng: number | null;
}

/** The founding group's home, and the fallback whenever none is known. */
export const LONDON: Home = {
  locality: "London",
  country: "United Kingdom",
  timezone: "Europe/London",
  lat: 51.5074,
  lng: -0.1278,
};

/** "London, United Kingdom" — how the prompts name the place. */
export function homeLabel(home: Home): string {
  return `${home.locality}, ${home.country}`;
}

/** Today's date (YYYY-MM-DD) on the home clock, not the server's. */
export function homeToday(home: Home, at: Date = new Date()): string {
  return localDate(localClock(home.timezone, at));
}

// Currency symbol for the price examples in the prompts. The model reads
// prices off the page in whatever currency they're in; this only stops the
// examples from teaching it that everything costs pounds. Countries not
// listed get a bare number example.
const CURRENCY: Record<string, string> = {
  "united kingdom": "£", "uk": "£", "england": "£", "scotland": "£", "wales": "£",
  "united states": "$", "usa": "$", "canada": "$", "australia": "$", "new zealand": "$",
  "singapore": "$", "hong kong": "$", "mexico": "$", "argentina": "$",
  "ireland": "€", "france": "€", "germany": "€", "spain": "€", "portugal": "€", "italy": "€",
  "netherlands": "€", "belgium": "€", "austria": "€", "greece": "€", "finland": "€",
  "estonia": "€", "latvia": "€", "lithuania": "€", "slovakia": "€", "slovenia": "€",
  "croatia": "€", "cyprus": "€", "malta": "€", "luxembourg": "€",
  "japan": "¥", "china": "¥", "india": "₹", "türkiye": "₺", "turkey": "₺",
  "south korea": "₩", "korea": "₩", "israel": "₪", "brazil": "R$", "south africa": "R",
  "switzerland": "CHF ", "sweden": "kr ", "norway": "kr ", "denmark": "kr ",
  "poland": "zł ", "czechia": "Kč ", "czech republic": "Kč ", "hungary": "Ft ",
  "thailand": "฿", "vietnam": "₫", "indonesia": "Rp ", "philippines": "₱",
  "united arab emirates": "AED ", "uae": "AED ", "nigeria": "₦", "kenya": "KSh ", "egypt": "E£",
};

export function currencySymbol(country: string): string | null {
  return CURRENCY[country.trim().toLowerCase()] ?? null;
}

/** "e.g. 'Free', '£12', '£8–£15'" — with the home currency, or none. */
export function priceExamples(home: Home): string {
  const c = currencySymbol(home.country);
  return c
    ? `e.g. 'Free', '${c}12', '${c}8–${c}15'`
    : "e.g. 'Free', '12', '8–15' (in the local currency, with its symbol)";
}

/**
 * Does this address already say which city it's in? True when it names
 * the home locality or country, or any other obvious city marker the model
 * was asked to include for out-of-home addresses ("…, Paris, France").
 * Used to decide whether the geocoder needs the home appended.
 */
export function namesCity(address: string, home: Home): boolean {
  const a = address.toLowerCase();
  if (a.includes(home.locality.toLowerCase())) return true;
  if (a.includes(home.country.toLowerCase())) return true;
  // "Street, Town, Country" — three or more comma parts almost always end
  // in a city (and often a country); the model writes them that way when
  // the place isn't at home.
  return address.split(",").map((s) => s.trim()).filter(Boolean).length >= 3;
}

/**
 * The geocoder query for an address: appended with the home when the
 * address doesn't name a city (a bare "20 Deptford Broadway" is a London
 * street until proven otherwise), left alone when it does. Never forces a
 * Paris address into London.
 */
export function geocodeQuery(address: string, home: Home): string {
  return namesCity(address, home) ? address : `${address}, ${homeLabel(home)}`;
}

/**
 * Geocode with the home as context, trusting an out-of-home match: the
 * suffixed query first when the address doesn't name a city, and the bare
 * address as the fallback (Nominatim returns nothing for "Rue de Rivoli,
 * London", so a mislabelled foreign address still lands where it is).
 */
export async function geocodeNearHome(
  geocode: (q: string) => Promise<{ lat: number; lng: number } | null>,
  address: string,
  home: Home,
): Promise<{ lat: number; lng: number } | null> {
  const query = geocodeQuery(address, home);
  const hit = await geocode(query);
  if (hit || query === address) return hit;
  const bare = await geocode(address);
  if (bare) return bare;
  // Last resort: a postcode alone. Geocoders know every UK postcode even
  // when they've never heard of the estate or venue in front of it.
  const postcode = ukPostcode(address);
  return postcode ? await geocode(`${postcode}, ${home.country}`) : null;
}

/** The UK postcode in an address, normalised to "PO18 0PX" form; null if none. */
export function ukPostcode(address: string): string | null {
  const m = address.toUpperCase().match(/\b([A-Z]{1,2}\d[A-Z\d]?)\s*(\d[A-Z]{2})\b/);
  return m ? `${m[1]} ${m[2]}` : null;
}

interface GroupHomeRow {
  home_locality: string | null;
  home_country: string | null;
  home_timezone: string | null;
  home_lat: number | null;
  home_lng: number | null;
}

/** Row → Home, filling anything unset from London. */
export function homeFromRow(row: GroupHomeRow | null | undefined): Home {
  if (!row) return LONDON;
  // A named home without coordinates stays coordinate-less rather than
  // borrowing London's; an unnamed one is London through and through.
  const named = Boolean(row.home_locality?.trim());
  return {
    locality: row.home_locality?.trim() || LONDON.locality,
    country: row.home_country?.trim() || LONDON.country,
    timezone: row.home_timezone?.trim() || LONDON.timezone,
    lat: row.home_lat ?? (named ? null : LONDON.lat),
    lng: row.home_lng ?? (named ? null : LONDON.lng),
  };
}

/** The home of `groupId`; London when the group has none or can't be read. */
export async function groupHome(db: SupabaseClient, groupId: string | null): Promise<Home> {
  if (!groupId) return LONDON;
  const { data } = await db
    .from("groups")
    .select("home_locality, home_country, home_timezone, home_lat, home_lng")
    .eq("id", groupId)
    .maybeSingle();
  return homeFromRow(data as GroupHomeRow | null);
}
