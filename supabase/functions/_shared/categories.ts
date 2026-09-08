/// The two category vocabularies, one per kind. A place is evergreen, so its
/// words describe what the building *is* (gallery, park); an event's describe
/// what's *on* (exhibition, gig). Keeping them apart is what stops a sculpture
/// park's homepage being filed as an "exhibition" between the restaurants.
export const EVENT_CATEGORIES = [
  "exhibition", "gig", "theatre", "film", "market", "festival", "talk", "workshop", "outdoors", "other",
] as const;
export const PLACE_CATEGORIES = [
  "restaurant", "cafe", "drink", "gallery", "museum", "park", "shop", "venue", "other",
] as const;

export type Kind = "event" | "place";

/// Words from the wrong list that have an obvious home in the right one.
const CROSS_KIND: Record<Kind, Record<string, string>> = {
  place: {
    exhibition: "gallery",
    theatre: "venue",
    gig: "venue",
    film: "venue",
    festival: "venue",
    market: "shop",
    outdoors: "park",
  },
  event: {
    gallery: "exhibition",
    museum: "exhibition",
    shop: "market",
    park: "outdoors",
    venue: "other",
    restaurant: "other",
    cafe: "other",
    drink: "other",
  },
};

/// Lower-cases and trims the model's category, then makes sure it belongs
/// to the vocabulary for this kind — mapping across when the intent is
/// clear, falling back to "other" when it isn't. Null stays null.
export function normaliseCategory(kind: Kind, raw: string | null | undefined): string | null {
  if (raw === null || raw === undefined) return null;
  const c = raw.trim().toLowerCase();
  if (!c) return null;
  const allowed: readonly string[] = kind === "place" ? PLACE_CATEGORIES : EVENT_CATEGORIES;
  if (allowed.includes(c)) return c;
  return CROSS_KIND[kind][c] ?? "other";
}
