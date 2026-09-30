// place-hours: a save's opening hours, fresh from Google each time (its
// terms let us keep the place ID, not the hours). Takes {item_id}; the
// save has to be in the caller's library (RLS), and have a place whose
// hours are its own and worth showing today (see hoursShown), or, with
// {planning: true}, worth having for picking a day (hoursForPlanning).
// Returns {hours} or {hours: null}.
import { corsHeaders } from "../_shared/geo.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { groupHome, homeToday } from "../_shared/home.ts";
import { hoursForPlanning, hoursShown, placeHours } from "../_shared/hours.ts";
import { consumeHours } from "../_shared/quota.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    if (!(req.headers.get("Authorization") ?? "").startsWith("Bearer ")) {
      return json({ error: "unauthorized" }, 401);
    }
    const caller = await resolveCaller(req);
    if (!caller) return json({ error: "not in a group" }, 403);

    const { item_id, planning } = await req.json().catch(() => ({})) as { item_id?: string; planning?: boolean };
    if (!item_id || !UUID.test(item_id)) return json({ error: "item_id required" }, 400);

    const { data: item } = await caller.client
      .from("items")
      .select("kind, title, venue, address, category, starts_on, ends_on, place_id")
      .eq("id", item_id)
      .maybeSingle();
    if (!item?.place_id) return json({ hours: null });
    const today = homeToday(await groupHome(caller.client, caller.groupId), new Date());
    if (!(planning === true ? hoursForPlanning(item, today) : hoursShown(item, today))) {
      return json({ hours: null });
    }

    if (!await consumeHours(admin(), caller.userId)) return json({ error: "daily limit reached" }, 429);
    return json({ hours: await placeHours(item.place_id, item) });
  } catch (e) {
    console.error(e);
    return json({ error: "internal error" }, 500);
  }
});
