// After the model answers: where the card is, where its opening hours come
// from, its picture and its colour. Each lookup gives way to the parse's
// deadline rather than run past it.

import type { ParsedCard, ParseRun } from "./ask.ts";
import {
  colorFromImageBytes,
  colorFromImageUrl,
  heroImageFromHtml,
  heroImageFromUrl,
  wikipediaImage,
  wikipediaQueries,
} from "./color.ts";
import { geocode } from "./geo.ts";
import { geocodeNearHome, type Home } from "./home.ts";
import { hoursApply } from "./hours.ts";
import { eventVenue, findPlace, isVenue, namedVenue, type PlaceMatch, photoUri, placePhotoLink } from "./places.ts";
import { isFetchable, isMapsUrl, linkKey, type Page } from "./read.ts";

type Coords = { lat: number; lng: number };

/// A lookup the card can do without: given the time left before the
/// deadline less a margin for sending the card, and dropped if that's
/// under `need`.
export type InTime = <T>(name: string, work: () => Promise<T>, fallback: T, need?: number) => Promise<T>;

export function inTimeFor(run: ParseRun): InTime {
  return async <T>(name: string, work: () => Promise<T>, fallback: T, need = 2_000): Promise<T> => {
    const room = (run.deadline ?? Infinity) - Date.now() - 1_500;
    if (room === Infinity) return work();
    const skip = () => {
      (run.skipped ??= []).push(name);
      return fallback;
    };
    if (room < need) return skip();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        work(),
        new Promise<T>((resolve) => timer = setTimeout(() => resolve(skip()), room)),
      ]);
    } finally {
      clearTimeout(timer);
    }
  };
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/// The accent colour, started before the model is asked. A screenshot
/// beats the page's og:image because it is exactly what the user saw.
/// Best-effort; null is fine.
export function earlyColour(
  screenshot: string | undefined,
  cover: string | null,
  page: Page | null,
): Promise<string | null> {
  return screenshot
    ? colorFromImageBytes(base64ToBytes(screenshot))
    : cover
    ? colorFromImageBytes(base64ToBytes(cover))
    : page?.ogImage
    ? colorFromImageUrl(page.ogImage)
    : Promise.resolve(null);
}

/// Does this card point at somewhere real? A source link, an official site,
/// coordinates or a street address all do. An event may also stand on a
/// named venue or a date — "Frieze London, October" is a real thing even
/// when geocoding fails. A place with none of these is a phantom.
export function isAnchored(
  card: Pick<ParsedCard, "kind" | "website" | "address" | "venue" | "starts_on">,
  from: { url: string | null; coords: Coords | null },
): boolean {
  if (from.url || from.coords) return true;
  if (card.website || card.address) return true;
  return card.kind === "event" && Boolean(card.venue || card.starts_on);
}

/// Where the card is, and the Google place that told us. A maps pin is
/// exact and stays; otherwise Google's match, then the address, then the
/// venue's name. Google's street address replaces the model's.
export async function locate(
  card: ParsedCard,
  home: Home,
  pin: Coords | null,
  /** The name on a maps pin, which beats the card's title for finding it. */
  pinName: string | null,
  inTime: InTime,
): Promise<{ coords: Coords | null; google: PlaceMatch | null }> {
  let coords = pin;
  // Google knows the street address of nearly every place, where the
  // model's is a best guess from search snippets. A match replaces it.
  let google: PlaceMatch | null = card.kind === "place"
    ? await inTime("place", () => findPlace(pinName ?? card.title, card, home, pin), null)
    : null;
  if (google) {
    card.address = google.address ?? card.address;
    if (!coords && google.lat != null && google.lng != null) {
      coords = { lat: google.lat, lng: google.lng };
    }
  }
  // Street addresses geocode far more reliably than small-venue names
  // (Nominatim rarely knows independent restaurants), so try those first.
  if (!coords && card.address) {
    coords = await inTime("geocode", () => geocodeNearHome(geocode, card.address!, home), null);
  }
  // "Online" or "TBA" is nowhere: searched for, it finds a town or a shop
  // of that name, so such a card stays without a pin.
  const venue = namedVenue(card.venue);
  const nowhere = Boolean(card.venue?.trim()) && !venue;
  if (!coords && !nowhere && (venue || card.area)) {
    coords = await inTime("geocode", () =>
      geocodeNearHome(
        geocode,
        [venue ?? card.title, card.area].filter(Boolean).join(", "),
        home,
      ), null);
  }
  // An event at a venue nothing else could place: ask Google for the venue.
  if (!coords && card.kind === "event" && venue) {
    google = await inTime("venue", () => findPlace(venue, card, home, null, { samePostcode: true }), null);
    if (google?.lat != null && google.lng != null) {
      coords = { lat: google.lat, lng: google.lng };
      card.address ??= google.address;
    }
  }
  return { coords, google };
}

/// The Google place the card's opening hours come from, if hours apply.
export function hoursPlace(
  card: ParsedCard,
  home: Home,
  coords: Coords | null,
  google: PlaceMatch | null,
  inTime: InTime,
): Promise<PlaceMatch | null> {
  if (!hoursApply(card)) return Promise.resolve(null);
  if (card.kind === "place") return Promise.resolve(google && isVenue(google) ? google : null);
  return inTime("hours", () => eventVenue(card, home, coords, google), null).catch(() => null);
}

/// The card's photo: whatever the saved page offered (og:image, JSON-LD,
/// or its largest content picture). If that's still empty, the official
/// website the model named — Reddit tips, blocked ticketing pages, maps
/// pins, and bare typed names all get a real venue photo this way — then
/// Wikipedia, then the place's own photo on Google. `googlePhoto` is that
/// last one's image itself, for its colour.
export async function picture(
  card: ParsedCard,
  from: {
    url: string | null;
    page: Page | null;
    own: { url: string; html: string | null } | null;
    /** The model's link for the thing's own page, tried already. */
    proposedLink: string | null;
  },
  google: PlaceMatch | null,
  inTime: InTime,
): Promise<{ imageUrl: string | null; googlePhoto: string | null }> {
  const { url, page, own, proposedLink } = from;
  let imageUrl = page?.ogImage ??
    (own?.html ? heroImageFromHtml(own.html, own.url) : null);
  const ownTried = !url && proposedLink ? linkKey(proposedLink) : null;
  if (
    !imageUrl && card.website && isFetchable(card.website) &&
    !isMapsUrl(card.website) && card.website !== url &&
    (ownTried === null || linkKey(card.website) !== ownTried)
  ) {
    imageUrl = await inTime("photo", () => heroImageFromUrl(card.website!), null);
  }
  // The generic Google Maps app icon once poisoned several saves with
  // rainbow-streak thumbnails — never let any maps-branded asset through.
  if (imageUrl && /(?:gstatic|googleusercontent)\.com.*maps|maps_\d+dp\.(?:png|webp)/i.test(imageUrl)) {
    imageUrl = null;
  }
  // Named festivals and museums often have a Wikipedia photo when the
  // listing page is a JS shell or the save had no URL at all. Short or
  // generic names never reach this (see wikipediaQueries).
  if (!imageUrl) {
    for (const query of wikipediaQueries(card)) {
      imageUrl = await inTime("wikipedia", () => wikipediaImage(query), null);
      if (imageUrl) break;
    }
  }

  // Last resort: the place's own photo on Google.
  let googlePhoto: string | null = null;
  if (!imageUrl && google?.photo) {
    const photo = google.photo, id = google.id, credit = google.credit;
    imageUrl = await inTime("google_photo", () => placePhotoLink(id, credit), null);
    googlePhoto = await inTime("google_photo", () => photoUri(photo, 400), null);
  }
  return { imageUrl, googlePhoto };
}

/// The accent colour: the early one if it came in time, else the photo's.
export async function colour(
  early: Promise<string | null>,
  photo: { imageUrl: string | null; googlePhoto: string | null },
  inTime: InTime,
): Promise<string | null> {
  const color = await inTime("colour", () => early.catch(() => null), null, 500);
  if (color) return color;
  const from = photo.googlePhoto ?? photo.imageUrl;
  return from ? await inTime("colour", () => colorFromImageUrl(from).catch(() => null), null) : null;
}
