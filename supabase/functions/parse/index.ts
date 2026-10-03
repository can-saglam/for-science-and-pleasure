// parse: stateless extraction endpoint. Takes {text?, image_base64?, image_media_type?}
// and returns a parsed card; nothing is stored. A member JWT is required —
// the home city comes from their group. The old ingest-secret path is gone.
import { internalErrorBody } from "../_shared/auth.ts";
import {
  corsHeaders,
  extractCard,
  firstUrl,
  looksLikeSearch,
  SocialUnreadableError,
  VagueInputError,
} from "../_shared/extract.ts";
import { assertImageWithinLimit } from "../_shared/limits.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { groupHome } from "../_shared/home.ts";
import { bumpVague, consumeQuota, quotaResponse, VAGUE_STRIKES, vagueStrikes } from "../_shared/quota.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

/// A search, not a save. `firm` (a string, so older builds still read the
/// body as strings) once the person has searched more than a few times
/// today: the app's note gets more direct.
async function vague(userId: string, message: string) {
  const strikes = await bumpVague(admin(), userId);
  return json({ error: message, code: "too_vague", ...(strikes > VAGUE_STRIKES ? { firm: "true" } : {}) }, 422);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  let userId: string | null = null;
  try {
    if (!(req.headers.get("Authorization") ?? "").startsWith("Bearer ")) {
      return json({ error: "unauthorized" }, 401);
    }
    const caller = await resolveCaller(req);
    if (!caller) {
      return json({ error: "not in a group" }, 403);
    }
    userId = caller.userId;

    const body = await req.json();
    if (!body.text && !body.image_base64) {
      return json({ error: "text or image_base64 required" }, 400);
    }

    // Typed words from someone who has already searched a few times today:
    // a quick check first, and a search is answered without a full lookup.
    // Links and pictures always go through.
    const text = typeof body.text === "string" ? body.text.trim() : "";
    if (
      text && !body.image_base64 && !firstUrl(text) &&
      await vagueStrikes(admin(), caller.userId) >= VAGUE_STRIKES &&
      await looksLikeSearch(text)
    ) {
      return await vague(caller.userId, new VagueInputError().message);
    }

    if (!await consumeQuota(admin(), caller.userId, "parse")) {
      return new Response(quotaResponse().body, {
        status: 429,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const home = await groupHome(caller.client, caller.groupId);

    try {
      assertImageWithinLimit(body.image_base64);
    } catch (limitErr) {
      return json({ error: String(limitErr) }, 413);
    }

    const card = await extractCard(body, home);
    return json({ card });
  } catch (e) {
    // A social post nothing could read: a question for the user, not a
    // server error. 422 so the app shows the message as-is (and doesn't
    // retry — see ParseClient.isTransient).
    if (e instanceof VagueInputError && userId) {
      return await vague(userId, e.message);
    }
    if (e instanceof SocialUnreadableError || e instanceof VagueInputError) {
      const code = e instanceof VagueInputError ? "too_vague" : "social_unreadable";
      return json({ error: e.message, code }, 422);
    }
    console.error(e);
    return new Response(internalErrorBody(), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
