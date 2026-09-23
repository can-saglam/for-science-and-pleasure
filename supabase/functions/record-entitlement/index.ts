// record-entitlement: a phone reports a Plus purchase (or a renewal, lapse
// or restore StoreKit told it about); this asks Apple what's true and
// writes the caller's own entitlements row.
//
//   POST { signed_transaction }  (StoreKit's jwsRepresentation)
//     → { is_plus, expires_at }                          recorded
//     → { error: "other_account" }                       409, bought by someone else
//     → { error: "unknown_transaction" }                 404, Apple doesn't know it
//
// The subscription belongs to whoever bought it: the app stamps the buyer's
// user id into the purchase (appAccountToken), and an original transaction
// already recorded for another account is never moved. Founder and promo
// rows are left alone: they never expire, so there is nothing to record.
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/extract.ts";
import { admin } from "../_shared/groups.ts";
import { appStoreConfigured, entitlementRow, jwsPayload, subscriptionStatus } from "../_shared/appstore.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

async function callerId(req: Request): Promise<string | null> {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return null;
  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) return null;
  return data.user.id;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const userId = await callerId(req);
  if (!userId) return json({ error: "sign in required" }, 401);
  if (!appStoreConfigured()) return json({ error: "not_configured" }, 503);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON body required" }, 400);
  }
  const jws = typeof body.signed_transaction === "string" ? body.signed_transaction : "";
  const claimed = jwsPayload<{ transactionId?: string; originalTransactionId?: string }>(jws);
  const lookup = claimed?.originalTransactionId ?? claimed?.transactionId;
  if (!lookup) return json({ error: "signed_transaction required" }, 400);

  const db = admin();
  const { data: mine } = await db.from("entitlements").select("source, expires_at").eq("user_id", userId).maybeSingle();
  if (mine && mine.source !== "app_store") {
    return json({ is_plus: true, expires_at: mine.expires_at });
  }

  let sub;
  try {
    sub = await subscriptionStatus(lookup);
  } catch (e) {
    console.error("record-entitlement: App Store lookup failed", e);
    return json({ error: "app_store_unavailable" }, 502);
  }
  if (!sub) return json({ error: "unknown_transaction" }, 404);
  if (sub.appAccountToken && sub.appAccountToken !== userId.toLowerCase()) {
    return json({ error: "other_account" }, 409);
  }

  const { data: owner } = await db.from("entitlements").select("user_id")
    .eq("original_transaction_id", sub.originalTransactionId).maybeSingle();
  if (owner && owner.user_id !== userId) return json({ error: "other_account" }, 409);

  const row = entitlementRow(userId, sub);
  const { error } = await db.from("entitlements").upsert(row, { onConflict: "user_id" });
  if (error) {
    console.error("record-entitlement: write failed", error);
    return json({ error: "write_failed" }, 500);
  }
  return json({ is_plus: new Date(row.expires_at) > new Date(), expires_at: row.expires_at });
});
