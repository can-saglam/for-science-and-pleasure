// digest: plain factual weekly summary, computed from the saved items.
// Pull-based: a Sunday-evening iOS Shortcut automation fetches this and
// shows it as a notification (see SHORTCUT.md). Auth via ?key=. Prefer
// FEED_SECRET; falls back to INGEST_SECRET until FEED_SECRET is configured.
import { createClient } from "npm:@supabase/supabase-js@2";
import { isFeedKeyAuthorized } from "../_shared/auth.ts";
import { buildDigest } from "../_shared/digest.ts";

Deno.serve(async (req) => {
  const key = new URL(req.url).searchParams.get("key");
  if (!isFeedKeyAuthorized(key)) {
    return new Response("unauthorized", { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: items, error } = await supabase
    .from("items")
    .select("id, kind, status, title, venue, area, category, price, starts_on, ends_on")
    .is("deleted_at", null)
    .in("status", ["saved", "planned"]);
  if (error) return new Response(String(error.message), { status: 500 });

  const text = buildDigest(items ?? []);
  return new Response(JSON.stringify({ text }), {
    headers: { "Content-Type": "application/json" },
  });
});
