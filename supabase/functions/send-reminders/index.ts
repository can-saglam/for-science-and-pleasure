// send-reminders: one APNs per save whose remind_at is today, to every
// device in the group (including whoever set it).
//
// pg_cron runs dispatch_reminders() every 15 minutes. It POSTs here with
// {group_id} for each group with a preset due and its home clock inside
// 10:00–10:59, or a hand-picked remind_time already past. This
// function re-checks both, dedups with reminder_runs (item_id, remind_at),
// and fans out. Without a group_id (manual runs) it does every group. `at`
// overrides the clock (tests). `force` bypasses the windows and the run
// table so a real send is unaffected.
//
// A plan's moment (an hour before its time, or 10:00) sends one alert to
// each phone its Live Activity didn't reach, deduped by plan_runs, and a
// reminder due on a planned day is left to the plan.
import { apnsConfigured, sendApnsAlert } from "../_shared/apns.ts";
import { sameSecret } from "../_shared/auth.ts";
import { admin, groupDevices } from "../_shared/groups.ts";
import { groupHome, homeToday } from "../_shared/home.ts";
import {
  type ActivityResult,
  alertTokens,
  planAlertBody,
  planClock,
  planDue,
  runActivities,
  type StartedOn,
} from "../_shared/live_activity.ts";
import {
  CUSTOM_REMINDER_TITLE,
  customReminderBody,
  customTimeDue,
  reminderBody,
} from "../_shared/reminders.ts";
import { dayBefore, isMorningHour, localClock } from "../_shared/schedule.ts";

type GroupResult =
  | { group_id: string; skipped: true; reason: string }
  | { group_id: string; items: number; apnsSent: number; apnsGone: number; apnsFailed: number }
  | { group_id: string; error: string };

interface DueItem {
  id: string;
  kind: string;
  title: string;
  starts_on: string | null;
  ends_on: string | null;
  reminder_offset_days: number;
  reminder_anchor: string;
  remind_at: string;
  /** HH:MM[:SS] on the home clock; null for the 10:00 presets. */
  remind_time: string | null;
  plan_on: string | null;
}

interface PlanItem {
  id: string;
  title: string;
  venue: string | null;
  area: string | null;
  plan_on: string;
  plan_time: string | null;
}

type PlanResult =
  | { group_id: string; plans: number; apnsSent: number; apnsGone: number; apnsFailed: number }
  | { group_id: string; error: string };

/** One alert per plan, when its moment comes, to each phone its Live
 * Activity didn't reach. A plan moved to a new time today alerts again. */
async function runPlans(
  supabase: ReturnType<typeof admin>,
  groupId: string,
  at: Date,
  startedOn: StartedOn,
): Promise<PlanResult> {
  const result = { group_id: groupId, plans: 0, apnsSent: 0, apnsGone: 0, apnsFailed: 0 };
  const home = await groupHome(supabase, groupId, true);
  const clock = localClock(home.timezone, at);
  const today = homeToday(home, at);

  const { data: rows, error } = await supabase
    .from("items")
    .select("id, title, venue, area, plan_on, plan_time")
    .eq("group_id", groupId)
    .eq("plan_on", today)
    .eq("status", "saved")
    .is("deleted_at", null);
  if (error) throw error;
  const due = ((rows ?? []) as PlanItem[]).filter((item) => planDue(item, today, clock));
  if (!due.length) return result;

  const devices = await groupDevices(supabase, groupId);
  for (const item of due) {
    const time = planClock(item.plan_time);
    const { data: sent, error: sentError } = await supabase
      .from("plan_runs")
      .select("plan_time")
      .eq("item_id", item.id)
      .eq("plan_on", today)
      .maybeSingle();
    if (sentError) throw sentError;
    if (sent && planClock(sent.plan_time) === time) continue;
    // Claiming only matches the row as it was read, so of two runs that
    // both saw it, one sends.
    let claimed = true;
    if (sent) {
      const retime = supabase
        .from("plan_runs")
        .update({ plan_time: time, sent_at: new Date().toISOString() })
        .eq("item_id", item.id)
        .eq("plan_on", today);
      const { data, error: claimError } = await (sent.plan_time == null
        ? retime.is("plan_time", null)
        : retime.eq("plan_time", sent.plan_time)).select("item_id");
      if (claimError) throw claimError;
      claimed = (data?.length ?? 0) > 0;
    } else {
      const { error: claimError } = await supabase
        .from("plan_runs")
        .insert({ item_id: item.id, plan_on: today, plan_time: time, group_id: groupId });
      if (claimError?.code === "23505") claimed = false;
      else if (claimError) throw claimError;
    }
    if (!claimed) continue;

    result.plans++;
    const tokens = alertTokens(devices, item.id, startedOn);
    const body = planAlertBody(item);
    let failed = 0;
    for (const token of tokens) {
      let sendResult;
      try {
        sendResult = await sendApnsAlert(token, body, item.title, { itemID: item.id }, groupId);
      } catch (e) {
        console.error("apns error", e);
        sendResult = "failed";
      }
      if (sendResult === "sent") result.apnsSent++;
      else if (sendResult === "gone") {
        result.apnsGone++;
        await supabase.from("apns_tokens").delete().eq("token", token);
      } else {
        result.apnsFailed++;
        failed++;
      }
    }
    // Nobody got it: the next tick tries again.
    if (tokens.length > 0 && failed === tokens.length) {
      await supabase.from("plan_runs").delete().eq("item_id", item.id).eq("plan_on", today);
    }
  }
  return result;
}

async function runGroup(
  supabase: ReturnType<typeof admin>,
  groupId: string,
  at: Date,
  force: boolean,
  startedOn: StartedOn = new Map(),
): Promise<GroupResult> {
  // Without push there's nothing to send, and a reminder marked done here
  // would never go out once it's fixed.
  if (!apnsConfigured()) return { group_id: groupId, skipped: true, reason: "apns not configured" };

  const home = await groupHome(supabase, groupId, true);
  const clock = localClock(home.timezone, at);
  const morning = isMorningHour(clock);

  const today = homeToday(home, at);
  // A hand-picked time in the last quarter hour of the day is only reached
  // by the first ticks after midnight.
  const yesterday = !force && clock.hour === "00" ? dayBefore(today) : null;

  const { data: rows, error: itemsError } = await supabase
    .from("items")
    .select("id, kind, title, starts_on, ends_on, reminder_offset_days, reminder_anchor, remind_at, remind_time, plan_on")
    .eq("group_id", groupId)
    .in("remind_at", yesterday ? [today, yesterday] : [today])
    .eq("status", "saved")
    .is("deleted_at", null);
  if (itemsError) throw itemsError;

  // Presets wait for the 10:00 hour; hand-picked times fire once the home
  // clock has passed them (reminder_runs stops a second send). A plan on
  // the same day speaks for itself.
  const due = ((rows ?? []) as DueItem[]).filter((item) => {
    if (item.plan_on === item.remind_at) return false;
    if (item.remind_at !== today) return item.remind_time != null;
    return force || (item.remind_time == null ? morning : customTimeDue(item.remind_time, clock));
  });
  if (!force && !morning && due.length === 0) {
    return { group_id: groupId, skipped: true, reason: "outside schedule" };
  }

  let items = 0;
  let apnsSent = 0;
  let apnsGone = 0;
  let apnsFailed = 0;

  const devices = await groupDevices(supabase, groupId);

  for (const item of due) {
    const tokens = alertTokens(devices, item.id, startedOn);
    if (!force) {
      const { data: existingRun, error: runError } = await supabase
        .from("reminder_runs")
        .select("status, started_at")
        .eq("item_id", item.id)
        .eq("remind_at", item.remind_at)
        .maybeSingle();
      if (runError) throw runError;
      if (existingRun?.status === "completed") continue;
      if (existingRun?.status === "running") {
        const started = existingRun.started_at ? Date.parse(existingRun.started_at) : 0;
        if (Date.now() - started < 20 * 60 * 1000) continue;
      }
      // Re-claiming only matches the row as it was read, so of two runs
      // that both saw it stale or failed, one sends.
      const { data: claimed, error } = existingRun
        ? await supabase
          .from("reminder_runs")
          .update({ status: "running", started_at: new Date().toISOString(), error: null })
          .eq("item_id", item.id)
          .eq("remind_at", item.remind_at)
          .eq("status", existingRun.status)
          .eq("started_at", existingRun.started_at)
          .select("item_id")
        : await supabase
          .from("reminder_runs")
          .insert({ item_id: item.id, remind_at: item.remind_at, status: "running" })
          .select("item_id");
      // A twin cron hit already claimed this row.
      if (error?.code === "23505") continue;
      if (error) throw error;
      if (!claimed?.length) continue;
    }

    items++;
    const custom = item.reminder_anchor === "custom";
    const body = custom
      ? customReminderBody(item.kind, item.title, item.remind_at, item.starts_on, item.ends_on)
      : reminderBody(item.reminder_offset_days, item.reminder_anchor, item.starts_on, item.ends_on);
    const pushTitle = custom ? CUSTOM_REMINDER_TITLE : item.title;

    let failed = 0;
    for (const token of tokens) {
      let result;
      try {
        result = await sendApnsAlert(token, body, pushTitle, { itemID: item.id }, groupId);
      } catch (error) {
        console.error("apns error", error);
        result = "failed";
      }
      if (result === "sent") apnsSent++;
      else if (result === "gone") {
        apnsGone++;
        await supabase.from("apns_tokens").delete().eq("token", token);
      } else {
        apnsFailed++;
        failed++;
      }
    }

    if (!force) {
      // Nobody got it: the next tick tries again. Anyone did: done, so no
      // phone hears it twice.
      const allFailed = tokens.length > 0 && failed === tokens.length;
      const update = allFailed
        ? { status: "failed", error: `${failed} of ${tokens.length} devices failed` }
        : { status: "completed", completed_at: new Date().toISOString() };
      let { error } = await supabase
        .from("reminder_runs")
        .update(update)
        .eq("item_id", item.id)
        .eq("remind_at", item.remind_at);
      if (error) {
        ({ error } = await supabase
          .from("reminder_runs")
          .update(update)
          .eq("item_id", item.id)
          .eq("remind_at", item.remind_at));
      }
      if (error) throw error;
    }
  }

  return { group_id: groupId, items, apnsSent, apnsGone, apnsFailed };
}

Deno.serve(async (req) => {
  const suppliedSecret = req.headers.get("x-cron-secret");
  const expectedSecret = Deno.env.get("REMINDERS_CRON_SECRET");
  if (!expectedSecret || !sameSecret(suppliedSecret, expectedSecret)) {
    return new Response("unauthorized", { status: 401 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabase = admin();
  const body = await req.json().catch(() => ({}));
  if (body.setup === true) {
    const { error } = await supabase.rpc("provision_reminders_cron", {
      p_function_url: `${supabaseUrl}/functions/v1/send-reminders`,
      p_cron_secret: expectedSecret,
    });
    if (error) return Response.json({ error: error.message }, { status: 500 });
    return Response.json({ configured: true });
  }

  const force = body.force === true;
  const at = typeof body.at === "string" && !Number.isNaN(Date.parse(body.at))
    ? new Date(body.at)
    : new Date();

  let groupIds: string[] = [];
  if (typeof body.group_id === "string") {
    groupIds = [body.group_id];
  } else {
    const { data, error } = await supabase.from("groups").select("id");
    if (error) return Response.json({ error: error.message }, { status: 500 });
    groupIds = (data ?? []).map((g: { id: string }) => g.id);
  }

  // Live Activities go first, in their own try: a phone a start reached
  // skips that save's reminder push, since the activity's alert is its
  // reminder. A failure there only means fewer phones skip — it can never
  // cost a reminder. Forced test runs leave them alone unless asked.
  const withActivities = apnsConfigured() && (!force || body.activities === true);
  const results: GroupResult[] = [];
  const activities: ActivityResult[] = [];
  const plans: PlanResult[] = [];
  for (const groupId of groupIds) {
    const startedOn: StartedOn = new Map();
    if (withActivities) {
      try {
        activities.push(await runActivities(supabase, groupId, at, startedOn));
      } catch (e) {
        console.error("live activities", e);
        activities.push({ group_id: groupId, error: force ? String(e).slice(0, 300) : "internal error" });
      }
      try {
        plans.push(await runPlans(supabase, groupId, at, startedOn));
      } catch (e) {
        console.error("plans", e);
        plans.push({ group_id: groupId, error: force ? String(e).slice(0, 300) : "internal error" });
      }
    }
    try {
      results.push(await runGroup(supabase, groupId, at, force, startedOn));
    } catch (e) {
      console.error(e);
      results.push({ group_id: groupId, error: force ? String(e).slice(0, 300) : "internal error" });
    }
  }
  return Response.json({ groups: results, activities, plans });
});
