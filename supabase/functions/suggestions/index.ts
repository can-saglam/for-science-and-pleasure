// suggestions: things on in a home city, for the add page, the empty
// library tabs and the first-save page. Body: { locality, country }. Answers from the
// stored pool straight away, ended events filtered out; a stale pool
// refreshes after the answer, so the next ask gets the new one. A city
// with no places yet waits for the quick knowledge call so the first ask
// has something, with curated starters behind it; the searched pool
// replaces it in the background. Only a brand-new city
// counts against the caller's daily limit. Authenticated (member JWT).
import { corsHeaders } from "../_shared/extract.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { consumeQuota } from "../_shared/quota.ts";
import { fallbackStarters, starterKey } from "../_shared/starters.ts";
import {
  BUSY_CITY_PEOPLE,
  type Refreshed,
  type Suggestion,
  type SuggestionKind,
  busyMatters,
  dress,
  isDue,
  leaseFree,
  triedRecently,
  refreshEvents,
  refreshPlaces,
  servePool,
  undressed,
} from "../_shared/suggestions.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

interface Row {
  kind: SuggestionKind;
  payload: unknown;
  fetched_at: string | null;
  refreshing_since: string | null;
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
    const { data } = await db
      .from("city_suggestions")
      .select("kind, payload, fetched_at, refreshing_since")
      .eq("key", key);
    const rows = (data ?? []) as Row[];
    const row = (kind: SuggestionKind) => rows.find((r) => r.kind === kind) ?? null;
    let busy = false;

    const record = async (kind: SuggestionKind, outcome: string, result: Refreshed | null, ms: number) => {
      const { error } = await db.from("suggestion_runs").insert({
        key,
        kind,
        outcome,
        busy: kind === "event" && busy,
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
          await note(summary);
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
        await note(`error after ${took()}: ${String(error).slice(0, 300)}`);
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

    const eventRow = row("event");
    const placeRow = row("place");
    let events = servePool(eventRow?.payload, "event", today);
    let places = servePool(placeRow?.payload, "place", today);
    const allowed = eventRow || placeRow ? true : await consumeQuota(db, caller.userId, "suggest");

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
    for (const [kind, pool, stored] of [["event", events, eventRow], ["place", places, placeRow]] as const) {
      if (!undressed(pool)) continue;
      if (busyRow(kind, stored)) {
        picturesComing = true;
      } else if (stored) {
        later.push(redress(kind));
        picturesComing = true;
      }
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
    return json({ events, places, events_coming: eventsComing, pictures_coming: picturesComing });
  } catch (e) {
    console.error(e);
    return json({ error: "internal error" }, 500);
  }
});
