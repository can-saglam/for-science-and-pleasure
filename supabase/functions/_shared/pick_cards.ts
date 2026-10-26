// Pick cards: each city pick's full card, stored with the pick in its pool
// so a tap saves it straight away instead of looking its link up again.
// Places get theirs free while being dressed (suggestions.ts). Events are
// read up front only for a city someone has just asked about, so a city
// kept warm on spec never pays to read pages nobody taps. Anything still
// without a card is looked up on its first tap, by parse, and kept here
// for everyone after. A new pool replaces the old one, cards and all.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isThumbnail } from "./color.ts";
import { extractCard, linkKey } from "./extract.ts";
import type { Home } from "./home.ts";
import { findPlace } from "./places.ts";
import { starterKey } from "./starters.ts";
import { type PickCard, placeCard, servePool, type Suggestion, type SuggestionKind } from "./suggestions.ts";

/// Picks never looked up. A tried one keeps `card: null`.
export function uncarded(items: Suggestion[]): boolean {
  return items.some((s) => s.card === undefined);
}

/// A card worth keeping for everyone: one that can go on the map. Without
/// a pin, the next tap looks it up again rather than everyone getting a
/// card that can't.
export function keepable(card: PickCard): boolean {
  return card.lat !== null && card.lng !== null;
}

/// The pick's own picture stands in when the page gave none (or only a
/// thumbnail), as it does when the phone saves a tapped pick.
export function withPickLook(card: PickCard, s: Suggestion): PickCard {
  if (card.image_url && (!isThumbnail(card.image_url) || !s.image)) return card;
  return { ...card, image_url: s.image ?? null, color: card.color ?? s.color ?? null };
}

/// A few reads side by side, each with its own limit, so a full pool of
/// events finishes well inside the worker's wall clock.
const READS_AT_ONCE = 4;
const READ_MS = 45_000;

/// Look up every pick without a card: a place on Google (as dressing it
/// does), an event by reading its page (as a tap would). A miss is null,
/// left for a tap.
export async function card(items: Suggestion[], home: Home): Promise<Suggestion[]> {
  const out = [...items];
  const pending = out.flatMap((s, at) => s.card === undefined ? [{ s, at }] : []);
  for (let i = 0; i < pending.length; i += READS_AT_ONCE) {
    await Promise.all(pending.slice(i, i + READS_AT_ONCE).map(async ({ s, at }) => {
      out[at] = { ...s, card: await cardFor(s, home) };
    }));
  }
  return out;
}

async function cardFor(s: Suggestion, home: Home): Promise<PickCard | null> {
  try {
    if (s.kind === "place") {
      const match = await findPlace(s.title, { area: s.venue }, home);
      return match ? placeCard(s, match, s.image ?? null, s.color ?? null) : null;
    }
    const found = await extractCard({ text: s.url }, home, undefined, undefined, { deadline: Date.now() + READ_MS });
    return keepable(found) ? withPickLook(found, s) : null;
  } catch {
    return null;
  }
}

/// The pick in the caller's home city that this link is, if it's one.
export async function poolPick(
  db: SupabaseClient,
  home: Home,
  link: string,
  today: string,
): Promise<{ key: string; pick: Suggestion } | null> {
  const want = linkKey(link);
  if (!want || !home.locality || !home.country) return null;
  const key = starterKey(home.locality, home.country);
  const { data } = await db.from("city_suggestions").select("kind, payload").eq("key", key);
  for (const row of (data ?? []) as { kind: SuggestionKind; payload: unknown }[]) {
    const pick = servePool(row.payload, row.kind, today).find((s) => linkKey(s.url) === want);
    if (pick) return { key, pick };
  }
  return null;
}

/// A tapped pick's lookup, kept for the rest of the city. Skipped when the
/// pool has moved on, another tap got there first, or there's no pin.
export async function storeCard(db: SupabaseClient, key: string, pick: Suggestion, found: PickCard): Promise<void> {
  if (!keepable(found)) return;
  const { data } = await db
    .from("city_suggestions")
    .select("payload")
    .eq("key", key)
    .eq("kind", pick.kind)
    .maybeSingle();
  const items = (data?.payload as { items?: unknown } | null)?.items;
  if (!Array.isArray(items)) return;
  let changed = false;
  const next = (items as Suggestion[]).map((s) => {
    if (s.url !== pick.url || s.card) return s;
    changed = true;
    return { ...s, card: withPickLook(found, s) };
  });
  if (!changed) return;
  const { error } = await db
    .from("city_suggestions")
    .update({ payload: { items: next } })
    .eq("key", key)
    .eq("kind", pick.kind);
  if (error) console.warn("pick card store failed", error.message);
}
