// parse: stateless extraction endpoint. Takes {text?, image_base64?, image_media_type?}
// and returns a parsed card; nothing is stored. Two callers, two auth paths:
// the web app sends a member's JWT, the iOS app sends the ingest secret
// (the same one already embedded in the share-sheet Shortcut).
import { internalErrorBody } from "../_shared/auth.ts";
import { corsHeaders, extractCard, SocialUnreadableError } from "../_shared/extract.ts";
import { assertImageWithinLimit } from "../_shared/limits.ts";
import { resolveCaller } from "../_shared/groups.ts";
import { groupHome, LONDON } from "../_shared/home.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const secret = req.headers.get("x-ingest-secret");
    const secretOk = Boolean(secret) && secret === Deno.env.get("INGEST_SECRET");
    // The caller's JWT is what tells us which group — and so which home
    // city — the parse is for. The secret alone still gets in (older
    // builds, the Shortcut) and parses against London.
    const caller = await resolveCaller(req);
    if (!secretOk && !caller) {
      // A signed-in user who isn't in a group yet can't use the parser
      // either — there's nowhere for the result to go.
      return new Response(JSON.stringify({ error: "not in a group" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const home = caller ? await groupHome(caller.client, caller.groupId) : LONDON;

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

    const card = await extractCard(body, home);
    return new Response(JSON.stringify({ card }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    // A social post nothing could read: a question for the user, not a
    // server error. 422 so the app shows the message as-is (and doesn't
    // retry — see ParseClient.isTransient).
    if (e instanceof SocialUnreadableError) {
      return new Response(JSON.stringify({ error: e.message, code: "social_unreadable" }), {
        status: 422,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    console.error(e);
    return new Response(internalErrorBody(), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
