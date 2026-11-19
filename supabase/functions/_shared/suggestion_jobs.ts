// The work behind a city's suggestions, shared by the app's ask
// (suggestions) and the scheduled warm-up (warm-cities): one job per row at
// a time, a search that replaces the pool, or pictures for a stored one.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { card, uncarded } from "./pick_cards.ts";
import {
  addUsage,
  type Refreshed,
  REFRESH_LEASE_MS,
  type Suggestion,
  type SuggestionKind,
  type Usage,
  describe,
  dress,
  label,
  refreshEvents,
  refreshPlaces,
  servePool,
  undescribed,
  undressed,
  unlabelled,
} from "./suggestions.ts";

/// What a run is assumed to spend until it says otherwise: about the
/// average of the runs so far. A worker cut off mid-search never says, and
/// its spend still counts against the budgets.
const EXPECTED: Record<SuggestionKind | "quick", { input_tokens: number; output_tokens: number; searches: number }> = {
  event: { input_tokens: 180_000, output_tokens: 32_000, searches: 12 },
  place: { input_tokens: 100_000, output_tokens: 4_000, searches: 6 },
  quick: { input_tokens: 1_000, output_tokens: 2_000, searches: 0 },
};

/// The outcome of a row that isn't a search: the extra reads of a stored
/// pool, there for the budgets only.
export const EXTRAS = "extras";

export interface City {
  key: string;
  locality: string;
  country: string;
  today: string;
  /// Started by the warm-up rather than someone's ask.
  warm?: boolean;
}

export function cityJobs(db: SupabaseClient, city: City, busy = () => false) {
  const { key, locality, country, today, warm = false } = city;

  /// The run's row, written before anything is spent with what it's
  /// expected to cost, so a run that never finishes still counts and still
  /// holds off the next try (triedRecently, warm_plan's `failed`).
  const begin = async (kind: SuggestionKind, quick: boolean): Promise<number | null> => {
    const { data, error } = await db.from("suggestion_runs").insert({
      key,
      kind,
      outcome: "started",
      busy: kind === "event" && busy(),
      warm,
      ...EXPECTED[quick ? "quick" : kind],
      total_ms: 0,
    }).select("id").single();
    if (error) console.error("suggestion_runs", error.message);
    return (data as { id: number } | null)?.id ?? null;
  };

  const record = async (
    run: number | null,
    kind: SuggestionKind,
    outcome: string,
    result: Refreshed | null,
    ms: number,
  ) => {
    const row = {
      key,
      kind,
      outcome,
      busy: kind === "event" && busy(),
      warm,
      proposed: result?.proposed ?? null,
      kept: result?.items.length ?? null,
      model: result?.usage.model ?? null,
      searches: result?.usage.searches ?? null,
      input_tokens: result?.usage.input_tokens ?? null,
      output_tokens: result?.usage.output_tokens ?? null,
      total_ms: ms,
    };
    const { error } = run === null
      ? await db.from("suggestion_runs").insert(row)
      : await db.from("suggestion_runs").update(row).eq("id", run);
    if (error) console.error("suggestion_runs", error.message);
  };

  /// What reading a stored pool cost (labels, descriptions, pick cards).
  const recordExtras = async (kind: SuggestionKind, usage: Usage, ms: number) => {
    if (usage.input_tokens === 0 && usage.output_tokens === 0) return;
    const { error } = await db.from("suggestion_runs").insert({
      key,
      kind,
      outcome: EXTRAS,
      warm,
      model: usage.model,
      searches: usage.searches,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_ms: ms,
    });
    if (error) console.error("suggestion_runs", error.message);
  };

  /// One job per row at a time: a refresh, or dressing an old pool.
  const claim = async (kind: SuggestionKind): Promise<boolean> => {
    await db
      .from("city_suggestions")
      .upsert({ key, kind, locality, country }, { onConflict: "key,kind", ignoreDuplicates: true });
    const now = new Date();
    const cutoff = new Date(now.getTime() - REFRESH_LEASE_MS).toISOString();
    const { data: claimed } = await db
      .from("city_suggestions")
      .update({ refreshing_since: now.toISOString() })
      .eq("key", key)
      .eq("kind", kind)
      .or(`refreshing_since.is.null,refreshing_since.lt.${cutoff}`)
      .select("key");
    return !!claimed?.length;
  };

  /// An empty or failed refresh keeps the old pool, and the next try
  /// waits a day (triedRecently). The quick first ask gives pictures a
  /// few seconds so it still answers fast; any it misses come with the
  /// searched pool that follows.
  const refresh = async (kind: SuggestionKind, quick = false): Promise<Suggestion[] | null> => {
    if (!await claim(kind)) return null;
    const started = Date.now();
    const run = await begin(kind, quick);
    const took = () => `${Math.round((Date.now() - started) / 1000)}s`;
    const note = (last_note: string) =>
      db.from("city_suggestions").update({ last_note }).eq("key", key).eq("kind", kind);
    let stage = "started";
    try {
      await note(stage);
      // The last pool's events still on carry over (see refreshEvents).
      const keep = kind === "event"
        ? servePool(
          (await db.from("city_suggestions").select("payload").eq("key", key).eq("kind", kind).maybeSingle())
            .data?.payload,
          kind,
          today,
        )
        : [];
      const result = kind === "event"
        ? await refreshEvents(locality, country, today, (s) => note(stage = `${s} (${took()})`), keep)
        : await refreshPlaces(locality, country, today, quick);
      const summary = `kept ${result.items.length} of ${result.proposed} in ${took()}; ${stage}`;
      await record(run, kind, result.items.length === 0 ? "empty" : "kept", result, Date.now() - started);
      if (result.items.length === 0) {
        await db.from("city_suggestions").update({ last_note: summary, refreshing_since: null })
          .eq("key", key).eq("kind", kind);
        return null;
      }
      const items = await dress(result.items, locality, country, quick ? 5_000 : undefined);
      await db
        .from("city_suggestions")
        .update({
          payload: { items },
          fetched_at: new Date().toISOString(),
          refreshing_since: null,
          last_note: summary,
        })
        .eq("key", key)
        .eq("kind", kind);
      return items;
    } catch (error) {
      console.error("suggestions refresh", kind, error);
      await db.from("city_suggestions")
        .update({ last_note: `error after ${took()}: ${String(error).slice(0, 300)}`, refreshing_since: null })
        .eq("key", key).eq("kind", kind);
      await record(run, kind, "error", null, Date.now() - started);
      return null;
    }
  };

  /// A pool stored before picks had pictures, before the chip named what
  /// they are, or before it said what they're like, gets that once,
  /// without a new search. Then the picks' cards (pick_cards.ts): always
  /// for places, which cost nothing more; for events only with
  /// `readEvents`, when someone in the city is asking.
  const redress = async (kind: SuggestionKind, readEvents = false) => {
    if (!await claim(kind)) return;
    const started = Date.now();
    let usage: Usage = { model: "", input_tokens: 0, output_tokens: 0, searches: 0 };
    const spent = (u: Usage) => {
      usage = addUsage({ ...usage, model: usage.model || u.model }, u);
    };
    try {
      const { data } = await db
        .from("city_suggestions")
        .select("payload")
        .eq("key", key)
        .eq("kind", kind)
        .maybeSingle();
      const stored = (data?.payload as { items?: unknown } | null)?.items;
      let items = Array.isArray(stored) ? stored as Suggestion[] : [];
      const save = (refreshing_since: string | null) =>
        db.from("city_suggestions").update({ payload: { items }, refreshing_since }).eq("key", key).eq("kind", kind);
      const cards = uncarded(items) && (kind === "place" || readEvents);
      if (undressed(items) || unlabelled(items) || undescribed(items)) {
        if (undressed(items)) items = await dress(items, locality, country);
        if (unlabelled(items)) items = await label(items, spent);
        if (undescribed(items)) items = await describe(items, spent);
        // Saved before the cards, which take longest, keeping the claim.
        if (cards) await save(new Date().toISOString());
      }
      if (cards) {
        items = await card(items, { locality, country, timezone: "UTC", lat: null, lng: null }, spent);
      }
      await save(null);
    } catch (error) {
      console.error("suggestions dress", kind, error);
      await db.from("city_suggestions").update({ refreshing_since: null }).eq("key", key).eq("kind", kind);
    }
    await recordExtras(kind, usage, Date.now() - started);
  };

  return { refresh, redress };
}
