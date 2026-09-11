// send-reminders: one APNs per dated save whose remind_at is today, to
// every device in the group (including whoever set it).
//
// pg_cron runs dispatch_reminders() every 15 minutes. For each group whose
// home clock is inside 10:00–10:59 it POSTs here with {group_id}. This
// function re-checks the window, dedups with reminder_runs (item_id,
// remind_at), and fans out. Without a group_id (manual runs) it does every
// group. `at` overrides the clock (tests). `force` bypasses the window and
// the run table so a real morning send is unaffected.
import { apnsConfigured, sendApnsAlert } from "../_shared/apns.ts";
import { admin, groupTokens } from "../_shared/groups.ts";
import { groupHome, homeToday } from "../_shared/home.ts";
import { reminderBody } from "../_shared/reminders.ts";
import { isMorningHour, localClock } from "../_shared/schedule.ts";

type GroupResult =
  | { group_id: string; skipped: true; reason: string }
  | { group_id: string; items: number; apnsSent: number; apnsGone: number; apnsFailed: number }
  | { group_id: string; error: string };

interface DueItem {
  id: string;
  title: string;
  starts_on: string | null;
  ends_on: string | null;
  reminder_offset_days: number;
  reminder_anchor: string;
  remind_at: string;
}

async function runGroup(
  supabase: ReturnType<typeof admin>,
  groupId: string,
  at: Date,
  force: boolean,
): Promise<GroupResult> {
  const home = await groupHome(supabase, groupId);
  const clock = localClock(home.timezone, at);
  if (!force && !isMorningHour(clock)) {
    return { group_id: groupId, skipped: true, reason: "outside schedule" };
  }

  const today = homeToday(home, at);

  const { data: rows, error: itemsError } = await supabase
    .from("items")
    .select("id, title, starts_on, ends_on, reminder_offset_days, reminder_anchor, remind_at")
    .eq("group_id", groupId)
    .eq("remind_at", today)
    .eq("status", "saved")
    .is("deleted_at", null);
  if (itemsError) throw itemsError;

  const due = (rows ?? []) as DueItem[];
  let items = 0;
  let apnsSent = 0;
  let apnsGone = 0;
  let apnsFailed = 0;

  const tokens = apnsConfigured() ? await groupTokens(supabase, groupId) : [];

  for (const item of due) {
    if (!force) {
      const { data: existingRun } = await supabase
        .from("reminder_runs")
        .select("status, started_at")
        .eq("item_id", item.id)
        .eq("remind_at", item.remind_at)
        .maybeSingle();
      if (existingRun?.status === "completed") continue;
      if (existingRun?.status === "running") {
        const started = existingRun.started_at ? Date.parse(existingRun.started_at) : 0;
        if (Date.now() - started < 20 * 60 * 1000) continue;
      }
      const { error } = existingRun
        ? await supabase
          .from("reminder_runs")
          .update({ status: "running", started_at: new Date().toISOString(), error: null })
          .eq("item_id", item.id)
          .eq("remind_at", item.remind_at)
        : await supabase
          .from("reminder_runs")
          .insert({ item_id: item.id, remind_at: item.remind_at, status: "running" });
      // A twin cron hit already claimed this row.
      if (error?.code === "23505") continue;
      if (error) throw error;
    }

    items++;
    const body = reminderBody(
      item.reminder_offset_days,
      item.reminder_anchor,
      item.starts_on,
      item.ends_on,
    );

    try {
      for (const token of tokens) {
        const result = await sendApnsAlert(token, body, item.title, { itemID: item.id });
        if (result === "sent") apnsSent++;
        else if (result === "gone") {
          apnsGone++;
          await supabase.from("apns_tokens").delete().eq("token", token);
        } else apnsFailed++;
      }

      if (!force) {
        await supabase
          .from("reminder_runs")
          .update({ status: "completed", completed_at: new Date().toISOString() })
          .eq("item_id", item.id)
          .eq("remind_at", item.remind_at);
      }
    } catch (error) {
      if (!force) {
        await supabase
          .from("reminder_runs")
          .update({ status: "failed", error: String(error) })
          .eq("item_id", item.id)
          .eq("remind_at", item.remind_at);
      }
      throw error;
    }
  }

  return { group_id: groupId, items, apnsSent, apnsGone, apnsFailed };
}

Deno.serve(async (req) => {
  const suppliedSecret = req.headers.get("x-cron-secret");
  const expectedSecret = Deno.env.get("REMINDERS_CRON_SECRET");
  if (!suppliedSecret || !expectedSecret || suppliedSecret !== expectedSecret) {
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

  const results: GroupResult[] = [];
  for (const groupId of groupIds) {
    try {
      results.push(await runGroup(supabase, groupId, at, force));
    } catch (e) {
      console.error(e);
      results.push({ group_id: groupId, error: force ? String(e).slice(0, 300) : "internal error" });
    }
  }
  return Response.json({ groups: results });
});
