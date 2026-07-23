// ingest: capture endpoint for the iOS share-sheet Shortcut. No user JWT —
// authenticated by a shared secret header. Parses the input and inserts the
// item directly (service role) with status 'inbox' for later confirmation.
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, extractCard } from "../_shared/extract.ts";

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

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    let row;
    try {
      const card = await extractCard(body);
      row = {
        kind: card.kind,
        status: "inbox",
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
        source: "shortcut",
        raw_input: body.text ?? "(screenshot)",
        added_by_email: body.added_by ?? null,
      };
    } catch (parseErr) {
      // Parsing failed (e.g. missing API key) — still save the raw dump so
      // nothing is lost; it shows up in the inbox for manual completion.
      console.error("parse failed, saving raw:", parseErr);
      row = {
        kind: "event",
        status: "inbox",
        title: (body.text ?? "Saved item").slice(0, 120),
        url: null,
        source: "shortcut",
        raw_input: body.text ?? "(screenshot)",
        added_by_email: body.added_by ?? null,
      };
    }

    const { data, error } = await supabase.from("items").insert(row).select("id, title").single();
    if (error) throw error;

    return new Response(JSON.stringify({ ok: true, id: data.id, title: data.title }), {
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
