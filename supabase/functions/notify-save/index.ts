// notify-save: called by the app right after a confirmed in-app save.
// Pushes "X added: …" to the other members of the caller's group (never
// the caller's own devices, never anyone outside the group).
import { corsHeaders } from "../_shared/geo.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { notifyPartnersOfSave } from "../_shared/notify.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const caller = await resolveCaller(req);
    if (!caller) {
      return new Response(JSON.stringify({ error: "not in a group" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { item_id } = await req.json();
    if (typeof item_id !== "string") {
      return new Response(JSON.stringify({ error: "item_id required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Read through the caller's own RLS: an item outside their group is
    // simply not found, so nobody can make us notify a group they're not in.
    const { data: item } = await caller.client
      .from("items")
      .select("id, title, venue, status, deleted_at, group_id")
      .eq("id", item_id)
      .maybeSingle();
    if (!item || item.deleted_at || item.status !== "saved") {
      return new Response(JSON.stringify({ sent: 0, skipped: true }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const result = await notifyPartnersOfSave(admin(), {
      itemId: item.id,
      title: item.title,
      venue: item.venue,
      groupId: item.group_id,
      adderUserId: caller.userId,
      adderEmail: caller.email,
    });
    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
