// digest: plain factual weekly summary, computed from the saved items.
// Pull-based: a Sunday-evening iOS Shortcut automation fetches this and
// shows it as a notification (see SHORTCUT.md). Auth via ?key=. Prefer
// FEED_SECRET; falls back to INGEST_SECRET until FEED_SECRET is configured.
import { admin, groupForFeedKey } from "../_shared/groups.ts";
import { buildDigest } from "../_shared/digest.ts";

Deno.serve(async (req) => {
  // The key in the URL is the group's feed_token (or the pre-groups
  // secret, which still maps to the founding group). It picks the group;
  // everything below is scoped to it.
  const supabase = admin();
  const groupId = await groupForFeedKey(supabase, new URL(req.url).searchParams.get("key"));
  if (!groupId) {
    return new Response("unauthorized", { status: 401 });
  }

  const { data: items, error } = await supabase
    .from("items")
    .select("id, kind, status, title, venue, area, category, price, starts_on, ends_on")
    .eq("group_id", groupId)
    .is("deleted_at", null)
    .in("status", ["saved", "planned"]);
  if (error) return new Response(String(error.message), { status: 500 });

  const text = buildDigest(items ?? []);
  return new Response(JSON.stringify({ text }), {
    headers: { "Content-Type": "application/json" },
  });
});
