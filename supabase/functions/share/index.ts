// share: a save sent to someone outside the library.
//   POST { item_id, card } (member JWT) → { token, url }. The card is what
//     the phone has, so a save made offline or just edited goes as it is.
//     Sharing the same save again keeps its link and refreshes the copy.
//   GET ?t=<token> (public) → { card, from }, for wegocan.com/s/<token> and
//     for the app, which opens it ready to save. `from` is the sender's
//     first name as the app shows it, or null.
import { corsHeaders } from "../_shared/extract.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { firstName, sharedCard, shareToken, SITE } from "../_shared/share.ts";

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", ...extra },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const db = admin();

    if (req.method === "GET") {
      const token = new URL(req.url).searchParams.get("t") ?? "";
      if (!/^[A-Za-z0-9]{10}$/.test(token)) return json({ error: "not found" }, 404);
      const { data } = await db.from("shared_saves").select("card, created_by").eq("token", token).maybeSingle();
      if (!data) return json({ error: "not found" }, 404);
      const { data: profile } = await db
        .from("profiles")
        .select("display_name")
        .eq("user_id", data.created_by)
        .maybeSingle();
      // A minute: a sender's re-share (or a new name) shows up soon after.
      return json({ card: data.card, from: firstName(profile?.display_name) }, 200, {
        "Cache-Control": "public, max-age=60",
      });
    }

    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    const caller = await resolveCaller(req);
    if (!caller) return json({ error: "not signed in" }, 401);
    const body = await req.json().catch(() => ({}));
    const itemId = typeof body.item_id === "string" ? body.item_id : "";
    const card = sharedCard(body.card);
    if (!/^[0-9a-f-]{36}$/i.test(itemId) || !card) return json({ error: "a save's card is required" }, 400);

    const { data: existing } = await db
      .from("shared_saves")
      .select("token")
      .eq("created_by", caller.userId)
      .eq("item_id", itemId)
      .maybeSingle();
    let token = existing?.token as string | undefined;
    if (token) {
      await db.from("shared_saves")
        .update({ card, updated_at: new Date().toISOString() })
        .eq("token", token);
    } else {
      token = shareToken();
      const { error } = await db.from("shared_saves")
        .insert({ token, item_id: itemId, created_by: caller.userId, card });
      // Two taps at once: the other one's link stands.
      if (error?.code === "23505") {
        const { data: raced } = await db
          .from("shared_saves")
          .select("token")
          .eq("created_by", caller.userId)
          .eq("item_id", itemId)
          .single();
        token = raced!.token as string;
      } else if (error) {
        throw error;
      }
    }
    return json({ token, url: `${SITE}/s/${token}` });
  } catch (e) {
    console.error(e);
    return json({ error: "internal error" }, 500);
  }
});
