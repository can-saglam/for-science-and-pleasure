// verify-entitlements: hourly, re-asks Apple about the App Store
// subscribers checked longest ago and refreshes expires_at, so a lapse or
// refund takes effect within a day without the App Store Server
// Notifications webhook. Each run takes a batch, a few at a time, and stops
// starting new ones once its time is up; whoever's left goes first next
// hour (checked_at, 0055). Anyone checked in the last 20 hours waits.
//
// Called by pg_cron (0031, hourly since 0055) with the shared cron secret.
// Founder and promo rows are never touched.
import { sameSecret } from "../_shared/auth.ts";
import { admin } from "../_shared/groups.ts";
import { appStoreConfigured, entitlementRow, subscriptionStatus } from "../_shared/appstore.ts";
import { recordResponse } from "../_shared/runs.ts";

const BATCH = 300;
const AT_ONCE = 6;
/// Well inside the edge function's wall clock, with a check's two 10s
/// Apple calls to spare.
const BUDGET_MS = 90_000;
const RECHECK_HOURS = 20;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const expected = Deno.env.get("REMINDERS_CRON_SECRET");
  if (!expected || !sameSecret(req.headers.get("x-cron-secret"), expected)) return json({ error: "forbidden" }, 403);
  if (!appStoreConfigured()) return json({ error: "not_configured" }, 503);

  const db = admin();
  const started = new Date();
  // Anything that could still be live, plus a week of recent lapses so a
  // late renewal after billing retry is picked back up.
  const since = new Date(started.getTime() - 7 * 24 * 3_600_000).toISOString();
  const stale = new Date(started.getTime() - RECHECK_HOURS * 3_600_000).toISOString();
  const { data: rows, error } = await db.from("entitlements")
    .select("user_id, original_transaction_id")
    .eq("source", "app_store")
    .not("original_transaction_id", "is", null)
    .gte("expires_at", since)
    .or(`checked_at.is.null,checked_at.lt.${stale}`)
    .order("checked_at", { ascending: true, nullsFirst: true })
    .limit(BATCH);
  if (error) return await recordResponse(db, "verify-entitlements", started, json({ error: error.message }, 500));

  const queue = [...(rows ?? [])];
  let checked = 0, updated = 0, failed = 0;
  const worker = async () => {
    while (queue.length > 0 && Date.now() - started.getTime() < BUDGET_MS) {
      const r = queue.shift()!;
      try {
        const sub = await subscriptionStatus(r.original_transaction_id!);
        const checkedAt = new Date().toISOString();
        const { error: writeError } = await db.from("entitlements")
          .update(sub ? { ...entitlementRow(r.user_id, sub), checked_at: checkedAt } : { checked_at: checkedAt })
          .eq("user_id", r.user_id);
        if (writeError) throw writeError;
        checked++;
        if (sub) updated++;
      } catch (e) {
        // Left unstamped, so it's near the front again next hour.
        failed++;
        console.error("verify-entitlements:", r.user_id, e);
      }
    }
  };
  await Promise.all(Array.from({ length: AT_ONCE }, worker));

  const summary = { due: rows?.length ?? 0, checked, updated, failed, left: queue.length };
  // A run where every check failed is Apple or the key, not one subscriber.
  const broken = failed > 0 && checked === 0;
  return await recordResponse(
    db, "verify-entitlements", started,
    json(broken ? { ...summary, error: "every check failed" } : summary, broken ? 502 : 200),
  );
});
