// share: a save sent to someone outside the library.
//   POST { item_id, card } (member JWT) → { token, url }. The card is what
//     the phone has, so a save made offline or just edited goes as it is.
//     Sharing the same save again keeps its link and refreshes the copy.
//   GET ?t=<token> (public) → { card, from }, for wegocan.com/s/<token> and
//     for the app, which opens it ready to save. `from` is the sender's
//     first name as the app shows it, or null.
//   GET ?i=<invite code> (public) → { status, from, members }, for
//     wegocan.com/join/<code>: who's asking, by first name (publicInvite).
//     An unknown code answers as an expired one, and an address that keeps
//     guessing gets that answer for every code for an hour.
import { corsHeaders } from "../_shared/extract.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { normaliseCode } from "../_shared/membership.ts";
import { firstName, publicInvite, sharedCard, shareToken, SITE } from "../_shared/share.ts";

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", ...extra },
  });
}

/// Wrong codes one address may try in an hour before every code reads as
/// dead to it. Someone typing a code from a message needs a few.
const LOOKUP_FAILS_PER_HOUR = 20;
/// New share links one person can make in a day.
const SHARES_PER_DAY = 50;

/// An unknown code reads like a dead one, so guessing can't tell them apart.
const noInvite = () => json({ status: "expired", from: null, members: [] }, 200, { "Cache-Control": "no-store" });

/// Who's asking, hashed: wegocan.com's own server passes on its visitor's
/// address with the shared key; anyone else is their own address.
async function lookupKey(req: Request): Promise<string> {
  const siteKey = Deno.env.get("SITE_LOOKUP_SECRET");
  const fromSite = siteKey && req.headers.get("x-site-key") === siteKey ? req.headers.get("x-visitor-ip") : null;
  const address = fromSite ?? req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(address));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function invite(db: ReturnType<typeof admin>, req: Request, raw: string | null): Promise<Response> {
  const who = await lookupKey(req);
  const hourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count: fails } = await db
    .from("public_lookups")
    .select("id", { count: "exact", head: true })
    .eq("who", who)
    .gte("at", hourAgo);
  if ((fails ?? 0) >= LOOKUP_FAILS_PER_HOUR) return noInvite();

  const code = normaliseCode(raw);
  const { data: inv } = code
    ? await db
      .from("group_invites")
      .select("group_id, created_by, expires_at, revoked_at")
      .eq("code", code)
      .maybeSingle()
    : { data: null };
  if (!inv) {
    await db.from("public_lookups").insert({ who });
    if (Math.random() < 0.02) {
      await db.from("public_lookups").delete().lt("at", new Date(Date.now() - 86_400_000).toISOString());
    }
    return noInvite();
  }
  const { data: rows } = await db
    .from("group_members")
    .select("user_id")
    .eq("group_id", inv.group_id)
    .order("joined_at");
  const ids = (rows ?? []).map((r) => r.user_id as string);
  const { data: profiles } = await db
    .from("profiles")
    .select("user_id, display_name, avatar_colour")
    .in("user_id", inv.created_by ? [...ids, inv.created_by] : ids);
  const byId = new Map((profiles ?? []).map((p) => [p.user_id as string, p]));
  const members = ids.map((id) => ({
    display_name: byId.get(id)?.display_name ?? null,
    avatar_colour: byId.get(id)?.avatar_colour ?? null,
  }));
  const from = inv.created_by ? byId.get(inv.created_by)?.display_name : null;
  return json(publicInvite(inv, from, members), 200, { "Cache-Control": "public, max-age=60" });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const db = admin();

    if (req.method === "GET") {
      const params = new URL(req.url).searchParams;
      if (params.has("i")) return await invite(db, req, params.get("i"));
      const token = params.get("t") ?? "";
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

    // A save that has reached the server must be in the sender's library.
    // One that hasn't (made offline a moment ago) goes on the card alone.
    const { data: item } = await db.from("items").select("group_id, deleted_at").eq("id", itemId).maybeSingle();
    if (item && (item.group_id !== caller.groupId || item.deleted_at)) return json({ error: "not your save" }, 403);

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
      const { count: today } = await db
        .from("shared_saves")
        .select("token", { count: "exact", head: true })
        .eq("created_by", caller.userId)
        .gte("created_at", new Date(Date.now() - 86_400_000).toISOString());
      if ((today ?? 0) >= SHARES_PER_DAY) return json({ error: "too many shares today" }, 429);
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
