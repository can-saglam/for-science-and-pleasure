// send-digest: the weekly "this weekend" push, one per group.
//
// pg_cron runs dispatch_weekly_digest() every 15 minutes. It walks
// digest_schedules and, for each group whose local clock is inside the
// hour after its chosen moment, POSTs here with {group_id}. This function
// re-checks the window, dedups with digest_runs (group_id, week_start),
// builds the digest from the group's items and pushes it to the group's
// devices. Without a group_id (manual runs) it does every group.
import { apnsConfigured, sendApnsAlert } from "../_shared/apns.ts";
import { buildDigest } from "../_shared/digest.ts";
import { admin, groupTokens } from "../_shared/groups.ts";

interface Schedule {
  group_id: string;
  day_of_week: number;
  hour: number;
  minute: number;
  timezone: string;
}

function localNow(timeZone: string) {
  let parts;
  try {
    parts = new Intl.DateTimeFormat("en-GB", {
      timeZone,
      weekday: "short",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date());
  } catch {
    return localNow("Europe/London"); // bad tz string in the row
  }
  return Object.fromEntries(parts.map(({ type, value }) => [type, value]));
}

const ISO_DOW: Record<string, number> = {
  Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7,
};

function previousMonday(date: string): string {
  const d = new Date(`${date}T00:00:00Z`);
  const dow = (d.getUTCDay() + 6) % 7; // Mon=0 … Sun=6
  d.setUTCDate(d.getUTCDate() - dow);
  return d.toISOString().slice(0, 10);
}

type GroupResult =
  | { group_id: string; skipped: true; reason: string }
  | { group_id: string; apnsSent: number; apnsGone: number; apnsFailed: number }
  | { group_id: string; error: string };

async function runGroup(
  supabase: ReturnType<typeof admin>,
  sched: Schedule,
  force: boolean,
): Promise<GroupResult> {
  const local = localNow(sched.timezone);
  const nowMinutes = Number(local.hour) * 60 + Number(local.minute);
  const schedMinutes = sched.hour * 60 + sched.minute;
  const due = ISO_DOW[local.weekday] === sched.day_of_week &&
    nowMinutes >= schedMinutes && nowMinutes <= schedMinutes + 59;
  if (!force && !due) {
    return { group_id: sched.group_id, skipped: true, reason: "outside schedule" };
  }

  const localDate = `${local.year}-${local.month}-${local.day}`;
  const weekStart = previousMonday(localDate);

  if (!force) {
    const { data: existingRun } = await supabase
      .from("digest_runs")
      .select("status")
      .eq("group_id", sched.group_id)
      .eq("week_start", weekStart)
      .maybeSingle();
    if (existingRun?.status === "completed" || existingRun?.status === "running") {
      return { group_id: sched.group_id, skipped: true, reason: `already ${existingRun.status}` };
    }
    const { error } = existingRun
      ? await supabase
        .from("digest_runs")
        .update({ status: "running", started_at: new Date().toISOString(), error: null })
        .eq("group_id", sched.group_id)
        .eq("week_start", weekStart)
      : await supabase
        .from("digest_runs")
        .insert({ group_id: sched.group_id, week_start: weekStart, status: "running" });
    if (error) throw error;
  }

  try {
    const { data: items, error: itemsError } = await supabase
      .from("items")
      .select("id, kind, status, title, venue, area, category, price, starts_on, ends_on")
      .eq("group_id", sched.group_id)
      .is("deleted_at", null)
      .eq("status", "saved");
    if (itemsError) throw itemsError;

    // The app computes the sheet live from its items; the push carries the
    // text and a flag that routes the tap to the digest sheet.
    const text = buildDigest(items ?? [], localDate);

    let apnsSent = 0;
    let apnsGone = 0;
    let apnsFailed = 0;
    if (apnsConfigured()) {
      for (const token of await groupTokens(supabase, sched.group_id)) {
        const result = await sendApnsAlert(
          token,
          text,
          "This weekend — Can We Go?",
          { digest: weekStart },
        );
        if (result === "sent") apnsSent++;
        else if (result === "gone") {
          apnsGone++;
          await supabase.from("apns_tokens").delete().eq("token", token);
        } else apnsFailed++;
      }
    }

    if (!force) {
      await supabase
        .from("digest_runs")
        .update({ status: "completed", completed_at: new Date().toISOString() })
        .eq("group_id", sched.group_id)
        .eq("week_start", weekStart);
    }
    return { group_id: sched.group_id, apnsSent, apnsGone, apnsFailed };
  } catch (error) {
    if (!force) {
      await supabase
        .from("digest_runs")
        .update({ status: "failed", error: String(error) })
        .eq("group_id", sched.group_id)
        .eq("week_start", weekStart);
    }
    console.error("digest failed for group", sched.group_id, error);
    return { group_id: sched.group_id, error: force ? String(error).slice(0, 300) : "internal error" };
  }
}

Deno.serve(async (req) => {
  const suppliedSecret = req.headers.get("x-cron-secret");
  const expectedSecret = Deno.env.get("WEEKLY_DIGEST_CRON_SECRET");
  if (!suppliedSecret || !expectedSecret || suppliedSecret !== expectedSecret) {
    return new Response("unauthorized", { status: 401 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabase = admin();
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

  let query = supabase
    .from("digest_schedules")
    .select("group_id, day_of_week, hour, minute, timezone");
  if (typeof body.group_id === "string") query = query.eq("group_id", body.group_id);
  const { data: schedules, error } = await query;
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const results: GroupResult[] = [];
  for (const sched of (schedules ?? []) as Schedule[]) {
    try {
      results.push(await runGroup(supabase, sched, force));
    } catch (e) {
      console.error(e);
      results.push({ group_id: sched.group_id, error: force ? String(e).slice(0, 300) : "internal error" });
    }
  }
  return Response.json({ groups: results });
});
