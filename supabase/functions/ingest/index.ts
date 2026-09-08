// ingest: capture endpoint for the iOS share-sheet Shortcut. No user JWT —
// authenticated by a shared secret header. Parses the input and inserts the
// item directly (service role) into the shared library.
import { internalErrorBody } from "../_shared/auth.ts";
import { corsHeaders, extractCard } from "../_shared/extract.ts";
import { admin, groupForEmail } from "../_shared/groups.ts";
import { groupHome } from "../_shared/home.ts";
import { assertImageWithinLimit } from "../_shared/limits.ts";
import { notifyPartnersOfSave } from "../_shared/notify.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const secret = req.headers.get("x-ingest-secret");
    if (!secret || secret !== Deno.env.get("INGEST_SECRET")) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    if (!body.text && !body.image_base64) {
      return new Response(JSON.stringify({ error: "text or image_base64 required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    try {
      assertImageWithinLimit(body.image_base64);
    } catch (limitErr) {
      return new Response(JSON.stringify({ error: String(limitErr) }), {
        status: 413,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = admin();

    // No JWT on this path, so the group comes from the Shortcut's added_by
    // email. Unknown sender → nowhere to file the save → refuse rather than
    // guess a group.
    const owner = await groupForEmail(supabase, body.added_by);
    if (!owner) {
      return new Response(
        JSON.stringify({ error: "added_by must be the email of a member of a group" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    let row;
    try {
      const card = await extractCard(body, await groupHome(supabase, owner.groupId));

      // Duplicate guard: same source URL already saved → don't create a twin.
      if (card.url) {
        const { data: existing } = await supabase
          .from("items")
          .select("id, title")
          .eq("group_id", owner.groupId)
          .eq("url", card.url)
          .is("deleted_at", null)
          .limit(1)
          .maybeSingle();
        if (existing) {
          return new Response(
            JSON.stringify({ ok: true, duplicate: true, id: existing.id, title: existing.title }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }
      }

      row = {
        kind: card.kind,
        status: "saved",
        title: card.title,
        summary: card.summary,
        venue: card.venue,
        area: card.area,
        address: card.address,
        category: card.category,
        price: card.price,
        url: card.url,
        booking_url: card.booking_url,
        starts_on: card.starts_on,
        ends_on: card.ends_on,
        lat: card.lat,
        lng: card.lng,
        color: card.color,
        source: "shortcut",
        raw_input: body.text ?? "(screenshot)",
        added_by_email: body.added_by ?? null,
        group_id: owner.groupId,
        created_by: owner.userId,
        updated_by: owner.userId,
      };
    } catch (parseErr) {
      // Parsing failed (e.g. missing API key) — still save the raw dump so
      // nothing is lost; it can be completed manually in the library.
      console.error("parse failed, saving raw:", parseErr);
      row = {
        kind: "event",
        status: "saved",
        title: (body.text ?? "Saved item").slice(0, 120),
        url: null,
        source: "shortcut",
        raw_input: body.text ?? "(screenshot)",
        added_by_email: body.added_by ?? null,
        group_id: owner.groupId,
        created_by: owner.userId,
        updated_by: owner.userId,
      };
    }

    const { data, error } = await supabase.from("items").insert(row).select("id, title, venue").single();
    if (error) throw error;

    // Tell the other person; best-effort, never fails the save.
    try {
      await notifyPartnersOfSave(supabase, {
        itemId: data.id,
        title: data.title,
        venue: data.venue,
        groupId: owner.groupId,
        adderUserId: owner.userId,
        adderEmail: row.added_by_email ?? null,
      });
    } catch (notifyErr) {
      console.error("partner notify failed", notifyErr);
    }

    return new Response(JSON.stringify({ ok: true, id: data.id, title: data.title }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(internalErrorBody(), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
