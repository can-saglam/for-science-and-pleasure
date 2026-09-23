// verify-entitlements: nightly, re-asks Apple about every App Store
// subscriber and refreshes expires_at, so a lapse or refund takes effect
// within a day without the App Store Server Notifications webhook.
//
// Called by pg_cron (0031_plus_jobs.sql) with the shared cron secret.
// Founder and promo rows are never touched.
import { admin } from "../_shared/groups.ts";
import { appStoreConfigured, entitlementRow, subscriptionStatus } from "../_shared/appstore.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const expected = Deno.env.get("REMINDERS_CRON_SECRET");
  if (!expected || req.headers.get("x-cron-secret") !== expected) return json({ error: "forbidden" }, 403);
  if (!appStoreConfigured()) return json({ error: "not_configured" }, 503);

  const db = admin();
  // Anything that could still be live, plus a week of recent lapses so a
  // late renewal after billing retry is picked back up.
  const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const { data: rows, error } = await db.from("entitlements")
    .select("user_id, original_transaction_id")
    .eq("source", "app_store")
    .not("original_transaction_id", "is", null)
    .gte("expires_at", since);
  if (error) return json({ error: error.message }, 500);

  let updated = 0, failed = 0;
  for (const r of rows ?? []) {
    try {
      const sub = await subscriptionStatus(r.original_transaction_id!);
      if (!sub) continue;
      const { error: writeError } = await db.from("entitlements")
        .update(entitlementRow(r.user_id, sub)).eq("user_id", r.user_id);
      if (writeError) throw writeError;
      updated++;
    } catch (e) {
      failed++;
      console.error("verify-entitlements:", r.user_id, e);
    }
  }
  return json({ checked: rows?.length ?? 0, updated, failed });
});
