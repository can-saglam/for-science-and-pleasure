// parse: stateless extraction endpoint. Takes {text?, image_base64?, image_media_type?}
// and returns a parsed card; nothing is stored. Two callers, two auth paths:
// the web app sends a member's JWT, the iOS app sends the ingest secret
// (the same one already embedded in the share-sheet Shortcut).
import { createClient } from "npm:@supabase/supabase-js@2";
import { internalErrorBody } from "../_shared/auth.ts";
import { corsHeaders, extractCard } from "../_shared/extract.ts";
import { assertImageWithinLimit } from "../_shared/limits.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const secret = req.headers.get("x-ingest-secret");
    const secretOk = Boolean(secret) && secret === Deno.env.get("INGEST_SECRET");
    if (!secretOk) {
      const authHeader = req.headers.get("Authorization") ?? "";
      const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_ANON_KEY")!,
        { global: { headers: { Authorization: authHeader } } },
      );
      const { data: isMember, error: memberErr } = await supabase.rpc("is_member");
      if (memberErr || !isMember) {
        return new Response(JSON.stringify({ error: "not a member" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
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

    const card = await extractCard(body);
    return new Response(JSON.stringify({ card }), {
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
