import { buildPushHTTPRequest } from "npm:@pushforge/builder@2.0.5";
import { createClient } from "npm:@supabase/supabase-js@2";
import { buildDigest } from "../_shared/digest.ts";

interface SubscriptionRow {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
}

function londonNow() {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date());
  return Object.fromEntries(parts.map(({ type, value }) => [type, value]));
}

function previousMonday(date: string): string {
  const monday = new Date(`${date}T00:00:00Z`);
  monday.setUTCDate(monday.getUTCDate() - 1);
  return monday.toISOString().slice(0, 10);
}

function isAllowedPushEndpoint(endpoint: string): boolean {
  try {
    const { hostname, protocol } = new URL(endpoint);
    if (protocol !== "https:") return false;
    return (
      hostname === "fcm.googleapis.com" ||
      hostname.endsWith(".push.apple.com") ||
      hostname.endsWith(".push.services.mozilla.com")
    );
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  const suppliedSecret = req.headers.get("x-cron-secret");
  const expectedSecret = Deno.env.get("WEEKLY_DIGEST_CRON_SECRET");
  if (!suppliedSecret || !expectedSecret || suppliedSecret !== expectedSecret) {
    return new Response("unauthorized", { status: 401 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabase = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const body = await req.json().catch(() => ({}));
  if (body.setup === true) {
    const { error } = await supabase.rpc("provision_weekly_digest_cron", {
      p_function_url: `${supabaseUrl}/functions/v1/send-digest`,
      p_cron_secret: expectedSecret,
    });
    if (error) return Response.json({ error: error.message }, { status: 500 });
    return Response.json({ configured: true });
  }

  // force: manual test run (still behind the cron secret) — bypasses the
  // schedule/dedup gates and skips run bookkeeping so the real weekly run
  // is unaffected; the response carries per-push failure details.
  const force = body.force === true;

  const local = londonNow();
  if (!force && (local.weekday !== "Tue" || local.hour !== "10")) {
    return Response.json({ skipped: true, reason: "outside London schedule" });
  }

  const localDate = `${local.year}-${local.month}-${local.day}`;
  const weekStart = previousMonday(localDate);

  if (!force) {
    const { data: existingRun } = await supabase
      .from("digest_runs")
      .select("status")
      .eq("week_start", weekStart)
      .maybeSingle();
    if (existingRun?.status === "completed" || existingRun?.status === "running") {
      return Response.json({ skipped: true, reason: `already ${existingRun.status}` });
    }

    if (existingRun) {
      const { error } = await supabase
        .from("digest_runs")
        .update({ status: "running", started_at: new Date().toISOString(), error: null })
        .eq("week_start", weekStart)
        .eq("status", "failed");
      if (error) throw error;
    } else {
      const { error } = await supabase
        .from("digest_runs")
        .insert({ week_start: weekStart, status: "running" });
      if (error) throw error;
    }
  }

  try {
    const { data: items, error: itemsError } = await supabase
      .from("items")
      .select("id, kind, status, title, venue, area, category, price, starts_on, ends_on")
      .is("deleted_at", null)
      .eq("status", "saved");
    if (itemsError) throw itemsError;

    // The sheet in the app computes its own summary live from the items,
    // so nothing is stored — the push just carries the text and a flag
    // telling the app to open the digest sheet.
    const text = buildDigest(items ?? [], localDate);

    const { data: subscriptions, error: subscriptionsError } = await supabase
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth");
    if (subscriptionsError) throw subscriptionsError;

    const privateJWK = JSON.parse(Deno.env.get("VAPID_PRIVATE_JWK")!);
    const adminContact = Deno.env.get("VAPID_SUBJECT")!;
    const appUrl =
      "https://can-saglam.github.io/for-science-and-pleasure/?digest=weekly";
    let sent = 0;
    let expired = 0;
    let failed = 0;
    const failures: { endpoint: string; detail: string }[] = [];

    for (const subscription of (subscriptions ?? []) as SubscriptionRow[]) {
      if (!isAllowedPushEndpoint(subscription.endpoint)) {
        failed++;
        failures.push({
          endpoint: subscription.endpoint.slice(0, 50),
          detail: "endpoint not allowed",
        });
        continue;
      }

      try {
        const pushRequest = await buildPushHTTPRequest({
          privateJWK,
          subscription: {
            endpoint: subscription.endpoint,
            keys: { p256dh: subscription.p256dh, auth: subscription.auth },
          },
          message: {
            payload: {
              title: "Can We Go? — This week",
              body: text,
              icon:
                "https://can-saglam.github.io/for-science-and-pleasure/icon-192.png",
              tag: `weekly-digest-${weekStart}`,
              data: { digestId: "weekly", url: appUrl },
            },
            adminContact,
            // No `topic`: Apple's push service rejects it (BadWebPushTopic);
            // the notification `tag` already collapses repeats client-side.
            options: {
              ttl: 86400,
              urgency: "normal",
            },
          },
        });

        const response = await fetch(pushRequest.endpoint, {
          method: "POST",
          headers: pushRequest.headers,
          body: pushRequest.body,
          redirect: "error",
        });
        if (response.ok) {
          sent++;
        } else if (response.status === 404 || response.status === 410) {
          expired++;
          await supabase.from("push_subscriptions").delete().eq("id", subscription.id);
        } else {
          failed++;
          const detail = `${response.status} ${(await response.text()).slice(0, 200)}`;
          failures.push({ endpoint: subscription.endpoint.slice(0, 50), detail });
          console.error("push failed", detail);
        }
      } catch (error) {
        failed++;
        failures.push({
          endpoint: subscription.endpoint.slice(0, 50),
          detail: String(error).slice(0, 200),
        });
        console.error("push error", error);
      }
    }

    if (!force) {
      await supabase
        .from("digest_runs")
        .update({ status: "completed", completed_at: new Date().toISOString() })
        .eq("week_start", weekStart);
    }

    return Response.json({
      sent,
      expired,
      failed,
      ...(force ? { failures } : {}),
    });
  } catch (error) {
    if (!force) {
      await supabase
        .from("digest_runs")
        .update({ status: "failed", error: String(error) })
        .eq("week_start", weekStart);
    }
    console.error(error);
    return Response.json(
      { error: force ? String(error).slice(0, 300) : "internal error" },
      { status: 500 },
    );
  }
});
