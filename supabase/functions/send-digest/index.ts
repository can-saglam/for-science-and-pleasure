import { createClient } from "npm:@supabase/supabase-js@2";
import { apnsConfigured, sendApnsAlert } from "../_shared/apns.ts";
import { buildDigest } from "../_shared/digest.ts";

function londonNow() {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date());
  return Object.fromEntries(parts.map(({ type, value }) => [type, value]));
}

const ISO_DOW: Record<string, number> = {
  Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7,
};

function previousMonday(date: string): string {
  const monday = new Date(`${date}T00:00:00Z`);
  monday.setUTCDate(monday.getUTCDate() - 1);
  return monday.toISOString().slice(0, 10);
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

  // The schedule lives in the database so both members share one time and
  // either app can move it. The cron dispatcher pings every 15 minutes;
  // this window (scheduled moment + 59 min) plus digest_runs dedup below
  // yields exactly one send per week, shortly after the chosen time.
  const local = londonNow();
  const { data: schedRow } = await supabase
    .from("digest_schedule")
    .select("day_of_week, hour, minute")
    .maybeSingle();
  const sched = schedRow ?? { day_of_week: 4, hour: 10, minute: 0 };
  const nowMinutes = Number(local.hour) * 60 + Number(local.minute);
  const schedMinutes = sched.hour * 60 + sched.minute;
  const due = ISO_DOW[local.weekday] === sched.day_of_week &&
    nowMinutes >= schedMinutes && nowMinutes <= schedMinutes + 59;
  if (!force && !due) {
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
    // telling the app to open the digest sheet. Native pushes only (the
    // PWA is retired); the `digest` flag routes the tap to the sheet.
    const text = buildDigest(items ?? [], localDate);

    let apnsSent = 0;
    let apnsGone = 0;
    let apnsFailed = 0;
    if (apnsConfigured()) {
      const { data: tokens } = await supabase.from("apns_tokens").select("token");
      for (const row of (tokens ?? []) as { token: string }[]) {
        const result = await sendApnsAlert(
          row.token,
          text,
          "This weekend — Can We Go?",
          { digest: weekStart },
        );
        if (result === "sent") apnsSent++;
        else if (result === "gone") {
          apnsGone++;
          await supabase.from("apns_tokens").delete().eq("token", row.token);
        } else apnsFailed++;
      }
    }

    if (!force) {
      await supabase
        .from("digest_runs")
        .update({ status: "completed", completed_at: new Date().toISOString() })
        .eq("week_start", weekStart);
    }

    return Response.json({ apnsSent, apnsGone, apnsFailed });
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
