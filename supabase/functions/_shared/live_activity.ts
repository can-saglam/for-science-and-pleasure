// Live Activities on the day. A "morning of" reminder (offset 0) or a
// hand-picked one puts the save on each group member's Lock Screen and
// Dynamic Island at the moment its reminder goes off (push-to-start). It
// runs up to eight hours, the system's cap, and is gone by midnight: the
// end push goes out in the last dispatcher tick before then, with the
// dismissal at the exact time. Runs beside the reminder push, never
// instead of it: nothing here touches reminder_runs or the alert.
import { sendLiveActivity } from "./apns.ts";
import type { admin } from "./groups.ts";
import { groupHome, homeToday } from "./home.ts";
import { customTimeDue } from "./reminders.ts";
import { homeInstant, localClock } from "./schedule.ts";

type Db = ReturnType<typeof admin>;

/** The system ends a Live Activity after eight hours. */
export const MAX_HOURS = 8;
/** Nothing starts this late; it would barely be on screen. */
export const LAST_START_MINUTE = 23 * 60;
/** Morning-of presets go off in the 10:00 hour. */
export const PRESET_MINUTE = 10 * 60;
/** The dispatcher ticks every 15 minutes: end in the tick before. */
const TICK_MS = 15 * 60 * 1000;

export interface ActivityItem {
  id: string;
  kind: string;
  title: string;
  venue: string | null;
  area: string | null;
  color: string | null;
  image_url: string | null;
  starts_on: string | null;
  ends_on: string | null;
  reminder_offset_days: number | null;
  reminder_anchor: string | null;
  remind_time: string | null;
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
  if (kind !== "event") return "Today";
  if (startsOn === today && (endsOn == null || endsOn === today)) return "On today";
  if (endsOn === today) return "Last day";
  if (startsOn === today) return "Opens today";
  if (startsOn && startsOn > today) return `Opens ${inDays(daysBetween(today, startsOn))}`;
  if (endsOn && endsOn > today) return `Closes ${inDays(daysBetween(today, endsOn))}`;
  return "Today";
}

export function activityPlace(item: Pick<ActivityItem, "venue" | "area">): string | null {
  const parts = [item.venue, item.area].map((s) => s?.trim()).filter((s): s is string => Boolean(s));
  return parts.length ? parts.join(" · ") : null;
}

/** A reminder for the day itself: the "morning of" preset, or one picked
 * by hand. The earlier presets stay notifications. */
export function isDayOf(item: Pick<ActivityItem, "reminder_offset_days" | "reminder_anchor" | "remind_time">): boolean {
  if (item.reminder_anchor === "custom") return item.remind_time != null;
  return item.reminder_offset_days === 0;
}

/** Its reminder has gone off, and it isn't too late in the day to start. */
export function startDue(
  item: Pick<ActivityItem, "reminder_offset_days" | "reminder_anchor" | "remind_time">,
  clock: { hour: string; minute: string },
): boolean {
  const minutes = Number(clock.hour) * 60 + Number(clock.minute);
  if (!isDayOf(item) || minutes >= LAST_START_MINUTE) return false;
  if (item.reminder_anchor === "custom") return customTimeDue(item.remind_time!, clock);
  return minutes >= PRESET_MINUTE;
}

/** Eight hours on, or midnight on the home clock, whichever comes first. */
export function activityEnd(timeZone: string, today: string, at: Date): Date {
  const cap = new Date(at.getTime() + MAX_HOURS * 3_600_000);
  const midnight = homeInstant(timeZone, today, 24);
  return cap < midnight ? cap : midnight;
}

/** The start push. `attributes` and `content-state` mirror the app's
 * `DayActivityAttributes` field for field; the alert is required for a
 * push-to-start, and carries no sound so the reminder push stays the only
 * one that makes a noise. */
export function startAps(item: ActivityItem, today: string, endsAt: Date): Record<string, unknown> {
  const label = activityLabel(item.kind, item.starts_on, item.ends_on, today);
  const place = activityPlace(item);
  const end = Math.floor(endsAt.getTime() / 1000);
  const attributes: Record<string, unknown> = {
    itemID: item.id,
    title: item.title,
    kind: item.kind,
    day: today,
    endsAt: end,
  };
  if (place) attributes.place = place;
  if (item.color) attributes.colorHex = item.color;
  if (item.image_url) attributes.imageURL = item.image_url;
  return {
    event: "start",
    "content-state": { label },
    "attributes-type": "DayActivityAttributes",
    attributes,
    "stale-date": end,
    alert: { title: item.title, body: place ? `${label} · ${place}` : label },
  };
}

/** A send that throws (timeout, connection) counts as a failed one. */
async function send(token: string, aps: Record<string, unknown>, expiresAt?: Date): Promise<string> {
  try {
    return await sendLiveActivity(token, aps, expiresAt);
  } catch (e) {
    console.error("live activity send", e);
    return "failed";
  }
}

export async function runActivities(db: Db, groupId: string, at: Date): Promise<ActivityResult> {
  const home = await groupHome(db, groupId, true);
  const clock = localClock(home.timezone, at);
  const today = homeToday(home, at);
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

  // End: its time is within a tick (dismissed at that time), or the save
  // is no longer on its reminder day (dismissed now).
  const { data: open, error: openError } = await db
    .from("live_activity_runs")
    .select("item_id, remind_at, ends_at")
    .eq("group_id", groupId)
    .is("ended_at", null);
  if (openError) throw openError;
  const runs = (open ?? []) as { item_id: string; remind_at: string; ends_at: string | null }[];
  if (runs.length) {
    // A failed read here would look like every save had gone.
    const { data: rows, error: rowsError } = await db
      .from("items")
      .select("id, kind, starts_on, ends_on, status, deleted_at, remind_at")
      .in("id", runs.map((r) => r.item_id));
    if (rowsError) throw rowsError;
    const byId = new Map((rows ?? []).map((r: { id: string }) => [r.id, r]));
    for (const run of runs) {
      const item = byId.get(run.item_id) as
        | { kind: string; starts_on: string | null; ends_on: string | null; status: string; deleted_at: string | null; remind_at: string | null }
        | undefined;
      const endsAt = run.ends_at ? new Date(run.ends_at) : at;
      const pastDay = run.remind_at < today;
      const gone = !item || item.deleted_at != null || item.status !== "saved" || item.remind_at !== run.remind_at;
      const nearlyOver = endsAt.getTime() - at.getTime() <= TICK_MS;
      if (!pastDay && !gone && !nearlyOver) continue;

      const dismissAt = gone || pastDay || endsAt <= at ? at : endsAt;
      const label = item ? activityLabel(item.kind, item.starts_on, item.ends_on, run.remind_at) : "Today";
      const { data: tokens, error: tokensError } = await db
        .from("live_activity_tokens").select("token").eq("item_id", run.item_id);
      if (tokensError) throw tokensError;
      for (const { token } of (tokens ?? []) as { token: string }[]) {
        tally(await send(token, {
          event: "end",
          "content-state": { label },
          "dismissal-date": Math.floor(dismissAt.getTime() / 1000),
        }));
      }
      await db.from("live_activity_tokens").delete().eq("item_id", run.item_id);
      await db.from("live_activity_runs")
        .update({ ended_at: new Date().toISOString() })
        .eq("item_id", run.item_id)
        .eq("remind_at", run.remind_at);
      result.ended++;
    }
  }

  // Start: each day-of reminder whose moment has come, once.
  const { data: dueRows, error } = await db
    .from("items")
    .select("id, kind, title, venue, area, color, image_url, starts_on, ends_on, reminder_offset_days, reminder_anchor, remind_time")
    .eq("group_id", groupId)
    .eq("remind_at", today)
    .eq("status", "saved")
    .is("deleted_at", null);
  if (error) throw error;
  const due = ((dueRows ?? []) as ActivityItem[]).filter((item) => startDue(item, clock));
  if (!due.length) return result;

  const { data: members, error: membersError } = await db
    .from("group_members").select("user_id").eq("group_id", groupId);
  if (membersError) throw membersError;
  const userIds = (members ?? []).map((m: { user_id: string }) => m.user_id);
  if (!userIds.length) return result;
  const { data: tokenRows, error: tokenError } = await db
    .from("activity_tokens").select("token").in("user_id", userIds);
  if (tokenError) throw tokenError;
  const tokens = ((tokenRows ?? []) as { token: string }[]).map((t) => t.token);
  if (!tokens.length) return result;

  const { data: startedRows, error: startedError } = await db
    .from("live_activity_runs")
    .select("item_id")
    .eq("remind_at", today)
    .in("item_id", due.map((i) => i.id));
  if (startedError) throw startedError;
  const started = new Set((startedRows ?? []).map((r: { item_id: string }) => r.item_id));
  const endsAt = activityEnd(home.timezone, today, at);

  for (const item of due) {
    if (started.has(item.id)) continue;
    const { error: claim } = await db
      .from("live_activity_runs")
      .insert({ item_id: item.id, remind_at: today, group_id: groupId, ends_at: endsAt.toISOString() });
    // A twin cron hit already claimed it.
    if (claim?.code === "23505") continue;
    if (claim) throw claim;
    const aps = startAps(item, today, endsAt);
    let failed = 0;
    for (const token of tokens) {
      const r = await send(token, aps, endsAt);
      tally(r);
      if (r === "gone") await db.from("activity_tokens").delete().eq("token", token);
      if (r === "failed") failed++;
    }
    // Nobody got it: let the next tick start it instead.
    if (failed === tokens.length) {
      await db.from("live_activity_runs").delete().eq("item_id", item.id).eq("remind_at", today);
    } else {
      result.started++;
    }
  }
  return result;
}
