// Live Activities on reminder days. From 09:00 on the home clock, every
// save on its reminder day goes onto each group member's Lock Screen and
// Dynamic Island (push-to-start); from 17:00 it's ended with a dismissal at
// 18:00, so it's gone by six. Runs beside the reminder push, never instead
// of it: nothing here touches reminder_runs or the alert.
import { sendLiveActivity } from "./apns.ts";
import type { admin } from "./groups.ts";
import { groupHome, homeToday } from "./home.ts";
import { homeInstant, localClock } from "./schedule.ts";

type Db = ReturnType<typeof admin>;

/** Starts from 09:00; after 17:00 only ends. */
export const START_MINUTE = 9 * 60;
export const END_MINUTE = 17 * 60;
/** Off the Lock Screen by 18:00. */
export const GONE_HOUR = 18;

export interface ActivityItem {
  id: string;
  kind: string;
  title: string;
  venue: string | null;
  area: string | null;
  color: string | null;
  starts_on: string | null;
  ends_on: string | null;
}

export type ActivityResult =
  | { group_id: string; started: number; ended: number; sent: number; gone: number; failed: number }
  | { group_id: string; error: string };

function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

function inDays(n: number): string {
  return n === 1 ? "tomorrow" : `in ${n} days`;
}

/** The short line on the Lock Screen and in the Dynamic Island. */
export function activityLabel(
  kind: string,
  startsOn: string | null,
  endsOn: string | null,
  today: string,
): string {
  if (kind !== "event") return "Reminder";
  if (startsOn === today && (endsOn == null || endsOn === today)) return "On today";
  if (endsOn === today) return "Last day";
  if (startsOn === today) return "Opens today";
  if (startsOn && startsOn > today) return `Opens ${inDays(daysBetween(today, startsOn))}`;
  if (endsOn && endsOn > today) return `Closes ${inDays(daysBetween(today, endsOn))}`;
  return "Reminder";
}

export function activityPlace(item: Pick<ActivityItem, "venue" | "area">): string | null {
  const parts = [item.venue, item.area].map((s) => s?.trim()).filter((s): s is string => Boolean(s));
  return parts.length ? parts.join(" · ") : null;
}

/** The start push. `attributes` and `content-state` mirror the app's
 * `DayActivityAttributes` field for field; the alert is required for a
 * push-to-start, and carries no sound so the reminder push stays the only
 * one that makes a noise. */
export function startAps(item: ActivityItem, today: string, goneAt: Date): Record<string, unknown> {
  const label = activityLabel(item.kind, item.starts_on, item.ends_on, today);
  const place = activityPlace(item);
  const attributes: Record<string, unknown> = {
    itemID: item.id,
    title: item.title,
    kind: item.kind,
    day: today,
    endsAt: Math.floor(goneAt.getTime() / 1000),
  };
  if (place) attributes.place = place;
  if (item.color) attributes.colorHex = item.color;
  return {
    event: "start",
    "content-state": { label },
    "attributes-type": "DayActivityAttributes",
    attributes,
    "stale-date": Math.floor(goneAt.getTime() / 1000),
    alert: { title: item.title, body: place ? `${label} · ${place}` : label },
  };
}

export async function runActivities(db: Db, groupId: string, at: Date): Promise<ActivityResult> {
  const home = await groupHome(db, groupId);
  const clock = localClock(home.timezone, at);
  const minutes = Number(clock.hour) * 60 + Number(clock.minute);
  const today = homeToday(home, at);
  const goneAt = homeInstant(home.timezone, today, GONE_HOUR);
  const result = { group_id: groupId, started: 0, ended: 0, sent: 0, gone: 0, failed: 0 };
  const tally = (r: string) => {
    if (r === "sent") result.sent++;
    else if (r === "gone") result.gone++;
    else result.failed++;
  };

  // Update tokens outlive their activity when the app registered one after
  // the end push went; nothing reads them after two days.
  await db.from("live_activity_tokens").delete()
    .lt("updated_at", new Date(at.getTime() - 2 * 86_400_000).toISOString());

  // End: the day's over (17:00 on, dismissed at 18:00) or the save is no
  // longer on its reminder day (dismissed now).
  const { data: open } = await db
    .from("live_activity_runs")
    .select("item_id, remind_at")
    .eq("group_id", groupId)
    .is("ended_at", null);
  const runs = (open ?? []) as { item_id: string; remind_at: string }[];
  if (runs.length) {
    const { data: rows } = await db
      .from("items")
      .select("id, kind, starts_on, ends_on, status, deleted_at, remind_at")
      .in("id", runs.map((r) => r.item_id));
    const byId = new Map((rows ?? []).map((r: { id: string }) => [r.id, r]));
    for (const run of runs) {
      const item = byId.get(run.item_id) as
        | { kind: string; starts_on: string | null; ends_on: string | null; status: string; deleted_at: string | null; remind_at: string | null }
        | undefined;
      const pastDay = run.remind_at < today;
      const gone = !item || item.deleted_at != null || item.status !== "saved" || item.remind_at !== run.remind_at;
      if (!pastDay && !gone && minutes < END_MINUTE) continue;

      const dismissAt = gone || pastDay || at >= goneAt ? at : goneAt;
      const label = item ? activityLabel(item.kind, item.starts_on, item.ends_on, run.remind_at) : "Reminder";
      const { data: tokens } = await db.from("live_activity_tokens").select("token").eq("item_id", run.item_id);
      for (const { token } of (tokens ?? []) as { token: string }[]) {
        const r = await sendLiveActivity(token, {
          event: "end",
          "content-state": { label },
          "dismissal-date": Math.floor(dismissAt.getTime() / 1000),
        });
        tally(r);
      }
      await db.from("live_activity_tokens").delete().eq("item_id", run.item_id);
      await db.from("live_activity_runs")
        .update({ ended_at: new Date().toISOString() })
        .eq("item_id", run.item_id)
        .eq("remind_at", run.remind_at);
      result.ended++;
    }
  }

  // Start: 09:00–16:59, each save on its reminder day, once.
  if (minutes < START_MINUTE || minutes >= END_MINUTE) return result;
  const { data: members } = await db.from("group_members").select("user_id").eq("group_id", groupId);
  const userIds = (members ?? []).map((m: { user_id: string }) => m.user_id);
  if (!userIds.length) return result;
  const { data: tokenRows } = await db.from("activity_tokens").select("token").in("user_id", userIds);
  const tokens = ((tokenRows ?? []) as { token: string }[]).map((t) => t.token);
  if (!tokens.length) return result;

  const { data: dueRows, error } = await db
    .from("items")
    .select("id, kind, title, venue, area, color, starts_on, ends_on")
    .eq("group_id", groupId)
    .eq("remind_at", today)
    .eq("status", "saved")
    .is("deleted_at", null);
  if (error) throw error;
  const due = (dueRows ?? []) as ActivityItem[];
  if (!due.length) return result;
  const { data: startedRows } = await db
    .from("live_activity_runs")
    .select("item_id")
    .eq("remind_at", today)
    .in("item_id", due.map((i) => i.id));
  const started = new Set((startedRows ?? []).map((r: { item_id: string }) => r.item_id));

  for (const item of due) {
    if (started.has(item.id)) continue;
    const { error: claim } = await db
      .from("live_activity_runs")
      .insert({ item_id: item.id, remind_at: today, group_id: groupId });
    // A twin cron hit already claimed it.
    if (claim?.code === "23505") continue;
    if (claim) throw claim;
    result.started++;
    const aps = startAps(item, today, goneAt);
    for (const token of tokens) {
      const r = await sendLiveActivity(token, aps);
      tally(r);
      if (r === "gone") await db.from("activity_tokens").delete().eq("token", token);
    }
  }
  return result;
}
