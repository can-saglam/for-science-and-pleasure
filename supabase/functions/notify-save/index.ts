// notify-save: called by the app right after a confirmed in-app save.
// Pushes "X added: …" to the other member's devices (never the caller's).
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/geo.ts";
import { notifyPartnersOfSave } from "../_shared/notify.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: isMember } = await userClient.rpc("is_member");
    const { data: userData } = await userClient.auth.getUser();
    if (!isMember || !userData.user) {
      return new Response(JSON.stringify({ error: "not a member" }), {
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

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: item } = await admin
      .from("items")
      .select("id, title, venue, status, deleted_at")
      .eq("id", item_id)
      .maybeSingle();
    if (!item || item.deleted_at || item.status !== "saved") {
      return new Response(JSON.stringify({ sent: 0, skipped: true }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const result = await notifyPartnersOfSave(admin, {
      itemId: item.id,
      title: item.title,
      venue: item.venue,
      adderUserId: userData.user.id,
      adderEmail: userData.user.email,
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
