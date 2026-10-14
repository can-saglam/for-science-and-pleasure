// notify-save: called by the app right after a confirmed in-app save, and
// (topic "plan") right after the caller plans a day for one. Pushes "X
// added: …" or "X planned it for …" to the other members of the caller's
// group (never the caller's own devices, never anyone outside the group).
import { internalErrorBody } from "../_shared/auth.ts";
import { corsHeaders } from "../_shared/geo.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { notifyPartnersOfPlan, notifyPartnersOfSave } from "../_shared/notify.ts";

/** A save pings once per ten minutes; a plan moved again soon after still
 *  gets its new day out, so its window is short. */
const DEBOUNCE_MS = { save: 10 * 60 * 1000, plan: 2 * 60 * 1000 };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const caller = await resolveCaller(req);
    if (!caller) return json({ error: "not in a group" }, 403);

    const { item_id, topic: rawTopic } = await req.json();
    if (typeof item_id !== "string") return json({ error: "item_id required" }, 400);
    const topic = rawTopic === "plan" ? "plan" : "save";

    // Read through the caller's own RLS: an item outside their group is
    // simply not found, so nobody can make us notify a group they're not in.
    const { data: item } = await caller.client
      .from("items")
      .select("id, title, venue, status, deleted_at, group_id, plan_on, plan_time, planned_by")
      .eq("id", item_id)
      .maybeSingle();
    if (!item || item.deleted_at || item.status !== "saved") {
      return json({ sent: 0, skipped: true });
    }
    // Only the person whose plan it is can announce it (planned_by is
    // stamped from the login by the items trigger).
    if (topic === "plan" && (!item.plan_on || item.planned_by !== caller.userId)) {
      return json({ sent: 0, skipped: true });
    }

    const db = admin();
    const { data: recent } = await db
      .from("notify_recent")
      .select("sent_at")
      .eq("group_id", item.group_id)
      .eq("item_id", item.id)
      .eq("actor", caller.userId)
      .eq("topic", topic)
      .maybeSingle();
    if (recent?.sent_at && Date.now() - new Date(recent.sent_at).getTime() < DEBOUNCE_MS[topic]) {
      return json({ sent: 0, skipped: true, reason: "debounced" }, 429);
    }
    await db.from("notify_recent").upsert({
      group_id: item.group_id,
      item_id: item.id,
      actor: caller.userId,
      topic,
      sent_at: new Date().toISOString(),
    }, { onConflict: "group_id,item_id,actor,topic" });

    const result = topic === "plan"
      ? await notifyPartnersOfPlan(db, {
        itemId: item.id,
        title: item.title,
        groupId: item.group_id,
        plannerUserId: caller.userId,
        plannerEmail: caller.email,
        planOn: item.plan_on,
        planTime: item.plan_time,
      })
      : await notifyPartnersOfSave(db, {
        itemId: item.id,
        title: item.title,
        venue: item.venue,
        groupId: item.group_id,
        adderUserId: caller.userId,
        adderEmail: caller.email,
      });
    return json(result);
  } catch (e) {
    console.error(e);
    return new Response(internalErrorBody(), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
