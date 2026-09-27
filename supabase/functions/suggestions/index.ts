// suggestions: things on in a home city, for the empty library tabs and
// the first-save page. Body: { locality, country }. Answers from the
// stored pool straight away, ended events filtered out; a stale pool
// refreshes after the answer, so the next ask gets the new one. A city
// with no places yet waits for the quick knowledge call so the first ask
// has something, with curated starters behind it. Only a brand-new city
// counts against the caller's daily limit. Authenticated (member JWT).
import { corsHeaders } from "../_shared/extract.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { consumeQuota } from "../_shared/quota.ts";
import { fallbackStarters, starterKey } from "../_shared/starters.ts";
import {
  type Suggestion,
  type SuggestionKind,
  isDue,
  leaseFree,
  refreshEvents,
  refreshPlaces,
  servePool,
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

    /// One refresh per row at a time. An empty or failed refresh keeps the
    /// old pool and holds the lease, so the next try waits it out.
    const refresh = async (kind: SuggestionKind): Promise<Suggestion[] | null> => {
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
      if (!claimed?.length) return null;
      const started = Date.now();
      const took = () => `${Math.round((Date.now() - started) / 1000)}s`;
      const note = (last_note: string) =>
        db.from("city_suggestions").update({ last_note }).eq("key", key).eq("kind", kind);
      let stage = "started";
      try {
        await note(stage);
        const result = kind === "event"
          ? await refreshEvents(locality, country, today, (s) => note(stage = `${s} (${took()})`))
          : await refreshPlaces(locality, country, today);
        const summary = `kept ${result.items.length} of ${result.proposed} in ${took()}; ${stage}`;
        if (result.items.length === 0) {
          await note(summary);
          return null;
        }
        await db
          .from("city_suggestions")
          .update({
            payload: { items: result.items },
            fetched_at: new Date().toISOString(),
            refreshing_since: null,
            last_note: summary,
          })
          .eq("key", key)
          .eq("kind", kind);
        return result.items;
      } catch (error) {
        console.error("suggestions refresh", kind, error);
        await note(`error after ${took()}: ${String(error).slice(0, 300)}`);
        return null;
      }
    };

    const eventRow = row("event");
    const placeRow = row("place");
    let events = servePool(eventRow?.payload, "event", today);
    let places = servePool(placeRow?.payload, "place", today);
    const allowed = eventRow || placeRow ? true : await consumeQuota(db, caller.userId, "suggest");

    const later: Promise<unknown>[] = [];
    let eventsComing = false;
    if (allowed) {
      if (places.length === 0 && leaseFree(placeRow?.refreshing_since ?? null)) {
        places = (await refresh("place")) ?? [];
      } else if (isDue(placeRow?.fetched_at ?? null, "place", places.length) && leaseFree(placeRow?.refreshing_since ?? null)) {
        later.push(refresh("place"));
      }
      if (isDue(eventRow?.fetched_at ?? null, "event", events.length) && leaseFree(eventRow?.refreshing_since ?? null)) {
        later.push(refresh("event"));
        eventsComing = events.length === 0;
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
    return json({ events, places, events_coming: eventsComing });
  } catch (e) {
    console.error(e);
    return json({ error: "internal error" }, 500);
  }
});
