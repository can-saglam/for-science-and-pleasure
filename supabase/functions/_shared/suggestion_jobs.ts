// The work behind a city's suggestions, shared by the app's ask
// (suggestions) and the scheduled warm-up (warm-cities): one job per row at
// a time, a search that replaces the pool, or pictures for a stored one.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type Refreshed,
  type Suggestion,
  type SuggestionKind,
  dress,
  refreshEvents,
  refreshPlaces,
} from "./suggestions.ts";

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

  const record = async (kind: SuggestionKind, outcome: string, result: Refreshed | null, ms: number) => {
    const { error } = await db.from("suggestion_runs").insert({
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
    });
    if (error) console.error("suggestion_runs", error.message);
  };

  /// One job per row at a time: a refresh, or dressing an old pool.
  const claim = async (kind: SuggestionKind): Promise<boolean> => {
    await db
      .from("city_suggestions")
      .upsert({ key, kind, locality, country }, { onConflict: "key,kind", ignoreDuplicates: true });
    const now = new Date();
    const cutoff = new Date(now.getTime() - 5 * 60_000).toISOString();
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
    const took = () => `${Math.round((Date.now() - started) / 1000)}s`;
    const note = (last_note: string) =>
      db.from("city_suggestions").update({ last_note }).eq("key", key).eq("kind", kind);
    let stage = "started";
    try {
      await note(stage);
      const result = kind === "event"
        ? await refreshEvents(locality, country, today, (s) => note(stage = `${s} (${took()})`))
        : await refreshPlaces(locality, country, today, quick);
      const summary = `kept ${result.items.length} of ${result.proposed} in ${took()}; ${stage}`;
      await record(kind, result.items.length === 0 ? "empty" : "kept", result, Date.now() - started);
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
      await record(kind, "error", null, Date.now() - started);
      return null;
    }
  };

  /// A pool stored before picks had pictures gets them once, without a
  /// new search.
  const redress = async (kind: SuggestionKind) => {
    if (!await claim(kind)) return;
    try {
      const { data } = await db
        .from("city_suggestions")
        .select("payload")
        .eq("key", key)
        .eq("kind", kind)
        .maybeSingle();
      const stored = (data?.payload as { items?: unknown } | null)?.items;
      const items = await dress(Array.isArray(stored) ? stored as Suggestion[] : [], locality, country);
      await db
        .from("city_suggestions")
        .update({ payload: { items }, refreshing_since: null })
        .eq("key", key)
        .eq("kind", kind);
    } catch (error) {
      console.error("suggestions dress", kind, error);
      await db.from("city_suggestions").update({ refreshing_since: null }).eq("key", key).eq("kind", kind);
    }
  };

  return { refresh, redress };
}
