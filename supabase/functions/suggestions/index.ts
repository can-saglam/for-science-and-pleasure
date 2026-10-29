// suggestions: things on in a home city, for the add page, the empty
// library tabs and the first-save page. Body: { locality, country, store }
// (store: an App Store install; each ask is logged in city_asks so the
// warm-up follows demand). Answers from the
// stored pool straight away, ended events filtered out; a stale pool
// refreshes after the answer, so the next ask gets the new one. A city
// with no places yet waits for the quick knowledge call so the first ask
// has something, with curated starters behind it; the searched pool
// replaces it in the background. Only a brand-new city
// counts against the caller's daily limit. Authenticated (member JWT).
import { corsHeaders } from "../_shared/extract.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { reserveQuota } from "../_shared/quota.ts";
import { runCost } from "../_shared/warm_plan.ts";
import { fallbackStarters, starterKey } from "../_shared/starters.ts";
import { uncarded } from "../_shared/pick_cards.ts";
import { cityJobs } from "../_shared/suggestion_jobs.ts";
import {
  BUSY_CITY_PEOPLE,
  type SuggestionKind,
  busyMatters,
  isDue,
  leaseFree,
  triedRecently,
  forPhone,
  servePool,
  undescribed,
  undressed,
  unlabelled,
} from "../_shared/suggestions.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

interface Row {
  kind: SuggestionKind;
  payload: unknown;
  fetched_at: string | null;
  refreshing_since: string | null;
}

/// Brand-new cities one person can start a search for in a day. Each sets
/// off several paid searches; someone moving or looking ahead needs one or
/// two.
const NEW_CITIES_PER_DAY = 3;
/// What searches people set off (not the warm-up) may spend in a UTC day.
/// Past it, cities answer from what's stored, and new ones get starters.
const ASKS_DAILY_BUDGET_USD = 10;

async function underAskBudget(db: ReturnType<typeof admin>): Promise<boolean> {
  const since = `${new Date().toISOString().slice(0, 10)}T00:00:00Z`;
  const { data, error } = await db
    .from("suggestion_runs")
    .select("input_tokens, output_tokens, searches")
    .eq("warm", false)
    .gte("at", since);
  if (error) {
    console.error("suggestion_runs", error.message);
    return false;
  }
  return (data ?? []).reduce((sum, r) => sum + runCost(r), 0) < ASKS_DAILY_BUDGET_USD;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const caller = await resolveCaller(req);
    if (!caller) return json({ error: "not in a group" }, 403);

    const body = await req.json().catch(() => ({}));
    const locality = typeof body.locality === "string" ? body.locality.trim() : "";
    const country = typeof body.country === "string" ? body.country.trim() : "";
    if (!locality || !country || locality.length > 80 || country.length > 80) {
      return json({ error: "locality and country required" }, 400);
    }

    const db = admin();
    const key = starterKey(locality, country);
    const today = new Date().toISOString().slice(0, 10);
    const [{ data, error: readError }, { error: askError }] = await Promise.all([
      db.from("city_suggestions").select("kind, payload, fetched_at, refreshing_since").eq("key", key),
      db.from("city_asks").upsert(
        { key, user_id: caller.userId, day: today, store: body.store === true },
        { onConflict: "key,user_id,day", ignoreDuplicates: true },
      ),
    ]);
    if (askError) console.error("city_asks", askError.message);
    // Not "a new city": that would spend the caller's limit and a search.
    if (readError) throw new Error(`city_suggestions: ${readError.message}`);
    const rows = (data ?? []) as Row[];
    const row = (kind: SuggestionKind) => rows.find((r) => r.kind === kind) ?? null;
    let busy = false;

    const { refresh, redress } = cityJobs(db, { key, locality, country, today }, () => busy);

    const eventRow = row("event");
    const placeRow = row("place");
    let events = servePool(eventRow?.payload, "event", today);
    let places = servePool(placeRow?.payload, "place", today);
    const allowed = await underAskBudget(db) &&
      (eventRow || placeRow ? true : await reserveQuota(db, caller.userId, "suggest", NEW_CITIES_PER_DAY));

    const lastTry = async (kind: SuggestionKind) => {
      const { data } = await db
        .from("suggestion_runs")
        .select("outcome, at")
        .eq("key", key)
        .eq("kind", kind)
        .order("at", { ascending: false })
        .limit(1)
        .maybeSingle();
      return data as { outcome: string; at: string } | null;
    };

    const later: Promise<unknown>[] = [];
    if (allowed && busyMatters(eventRow?.fetched_at ?? null, "event")) {
      const { data: people } = await db.rpc("city_people", { p_key: key });
      busy = typeof people === "number" && people >= BUSY_CITY_PEOPLE;
    }
    const refreshing = new Set<SuggestionKind>();
    if (allowed) {
      if (places.length === 0 && leaseFree(placeRow?.refreshing_since ?? null)) {
        places = (await refresh("place", true)) ?? [];
        if (places.length > 0) {
          later.push(refresh("place"));
          refreshing.add("place");
        }
      } else if (
        isDue(placeRow?.fetched_at ?? null, "place", places.length) &&
        leaseFree(placeRow?.refreshing_since ?? null) &&
        !triedRecently(await lastTry("place"))
      ) {
        later.push(refresh("place"));
        refreshing.add("place");
      }
      if (
        isDue(eventRow?.fetched_at ?? null, "event", events.length, new Date(), busy) &&
        leaseFree(eventRow?.refreshing_since ?? null) &&
        !triedRecently(await lastTry("event"))
      ) {
        later.push(refresh("event"));
        refreshing.add("event");
      }
    }
    // "Coming" while any job is on the row, not just one this ask started,
    // so a phone asking again mid-search keeps waiting for it.
    const busyRow = (kind: SuggestionKind, stored: Row | null) =>
      refreshing.has(kind) || !leaseFree(stored?.refreshing_since ?? null);
    const eventsComing = events.length === 0 && busyRow("event", eventRow);
    let picturesComing = false;
    let categoriesComing = false;
    let descriptionsComing = false;
    let cardsComing = false;
    for (const [kind, pool, stored] of [["event", events, eventRow], ["place", places, placeRow]] as const) {
      const needsDress = undressed(pool);
      const needsLabel = unlabelled(pool);
      const needsAbout = undescribed(pool);
      // Someone is asking, so this city is in use: its events are read
      // up front too (pick_cards.ts).
      const needsCards = uncarded(pool);
      if (!needsDress && !needsLabel && !needsAbout && !needsCards) continue;
      if (!busyRow(kind, stored)) {
        if (!stored) continue;
        later.push(redress(kind, true));
      }
      if (needsDress) picturesComing = true;
      if (needsLabel) categoriesComing = true;
      if (needsAbout) descriptionsComing = true;
      if (needsCards) cardsComing = true;
    }
    if (later.length > 0) {
      const work = Promise.all(later);
      if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(work);
    }

    if (places.length === 0) {
      places = fallbackStarters(locality, country).map((s) => ({
        ...s,
        kind: "place" as const,
        venue: null,
        starts_on: null,
        ends_on: null,
      }));
    }
    return json({
      events: forPhone(events),
      places: forPhone(places),
      events_coming: eventsComing,
      pictures_coming: picturesComing,
      categories_coming: categoriesComing,
      descriptions_coming: descriptionsComing,
      cards_coming: cardsComing,
    });
  } catch (e) {
    console.error(e);
    return json({ error: "internal error" }, 500);
  }
});
