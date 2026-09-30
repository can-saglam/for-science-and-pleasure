// Live Activities on the day. A "morning of" reminder (offset 0) or a
// hand-picked one puts the save on each group member's Lock Screen and
// Dynamic Island at the moment its reminder goes off (push-to-start). It
// runs up to eight hours, the system's cap, and is gone by midnight: the
// end push goes out in the last dispatcher tick before then, with the
// dismissal at the exact time. It runs before the reminder push and stands
// in for it on each phone it reached (see `startedOn`); nothing here
// touches reminder_runs, and any phone it didn't reach still gets the alert.
//
// A plan does the same an hour before its time (10:00 without one) and
// leaves at the venue's closing time, four hours after the time, or
// midnight, whichever comes first. It stands in for a reminder on the same
// day: one activity per save per day, and the plan's wins. Moving or
// dropping the plan ends its activity; a moved one starts again.
import { sendLiveActivity } from "./apns.ts";
import type { admin } from "./groups.ts";
import { groupHome, homeToday } from "./home.ts";
import { closeMinutes, type Hours, hoursLine, hoursShown, minutes, placeHours } from "./hours.ts";
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
/** A planned time goes on the Lock Screen this long before. */
export const PLAN_LEAD_MINUTES = 60;
/** …and stays this long after, at most. */
export const PLAN_STAY_MINUTES = 4 * 60;
/** A plan without a time starts with the morning presets. */
export const PLAN_DAY_MINUTE = PRESET_MINUTE;

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
  category?: string | null;
  address?: string | null;
  place_id?: string | null;
  remind_at?: string | null;
  plan_on?: string | null;
  /** HH:MM[:SS] on the home clock. */
  plan_time?: string | null;
}

export type ActivityResult =
  | { group_id: string; started: number; ended: number; sent: number; gone: number; failed: number }
  | { group_id: string; error: string };

/** The phones a start push was accepted for in this run, per save, as
 * `deviceKey`s. The day's reminder alert skips them: the activity's own
 * alert is their reminder. */
export type StartedOn = Map<string, Set<string>>;

export function deviceKey(userId: string, deviceId: string): string {
  return `${userId}:${deviceId}`;
}

/** The APNs tokens a save's reminder alert still goes to: every phone but
 * those its Live Activity reached. A token with no device on record can't
 * be matched, so it gets the alert. */
export function alertTokens(
  devices: { token: string; user_id: string; device_id: string | null }[],
  itemId: string,
  startedOn: StartedOn,
): string[] {
  const reached = startedOn.get(itemId);
  return devices
    .filter((d) => !(reached && d.device_id && reached.has(deviceKey(d.user_id, d.device_id))))
    .map((d) => d.token);
}

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

/** Today's hours for a save whose venue has them, or null. One Google
 * call per save, not per phone; a slow answer is left out. */
export async function activityHours(item: ActivityItem, today: string, at: Date): Promise<Hours | null> {
  if (!item.place_id || !hoursShown({ ...item, category: item.category ?? null }, today)) return null;
  return await placeHours(item.place_id, item, at, 4_000);
}

/** The Lock Screen's hours line at `at`. */
export function hoursLineAt(hours: Hours | null, at: Date): string | null {
  if (!hours) return null;
  const local = new Date(at.getTime() + hours.offset * 60_000);
  return hoursLine(hours, local.getUTCHours() * 60 + local.getUTCMinutes());
}

/** HH:MM out of Postgres's HH:MM:SS. */
export function planClock(planTime: string | null | undefined): string | null {
  return planTime ? planTime.slice(0, 5) : null;
}

/** The plan's moment has come: an hour before its time, or 10:00 without
 * one (and not after 23:00, when it would barely be on screen). */
export function planDue(
  item: Pick<ActivityItem, "plan_on" | "plan_time">,
  today: string,
  clock: { hour: string; minute: string },
): boolean {
  if (item.plan_on !== today) return false;
  const now = Number(clock.hour) * 60 + Number(clock.minute);
  const time = planClock(item.plan_time);
  if (!time) return now >= PLAN_DAY_MINUTE && now < LAST_START_MINUTE;
  return now >= minutes(time) - PLAN_LEAD_MINUTES;
}

/** When the venue closes today, as an instant, if that's still ahead: the
 * opening the planned time falls in, or the day's last without a time. An
 * opening that runs past midnight is left to the midnight cap. */
export function closingTime(hours: Hours | null, planTime: string | null, at: Date): Date | null {
  const day = hours?.status === "open" ? hours.days[0] : undefined;
  if (!hours || !day?.ranges.length) return null;
  const range = planTime
    ? day.ranges.find((r) => minutes(planTime) >= minutes(r.open) && minutes(planTime) < closeMinutes(r))
    : day.ranges[day.ranges.length - 1];
  if (!range || closeMinutes(range) >= 1440) return null;
  const close = new Date(Date.parse(`${day.date}T00:00:00Z`) + (closeMinutes(range) - hours.offset) * 60_000);
  return close > at ? close : null;
}

/** A plan's activity leaves at the earliest of: closing time, four hours
 * after the planned time, and the usual eight hours or midnight. */
export function planEnd(
  timeZone: string,
  today: string,
  at: Date,
  planTime: string | null,
  closesAt: Date | null,
): Date {
  const ends = [activityEnd(timeZone, today, at)];
  if (planTime) ends.push(homeInstant(timeZone, today, 0, minutes(planTime) + PLAN_STAY_MINUTES));
  if (closesAt) ends.push(closesAt);
  return new Date(Math.min(...ends.map((d) => d.getTime())));
}

/** "Going 17:00" on the Lock Screen when there's a time; the usual line
 * otherwise. */
export function planLabel(item: Pick<ActivityItem, "kind" | "starts_on" | "ends_on" | "plan_time">, today: string): string {
  const time = planClock(item.plan_time);
  return time ? `Going ${time}` : activityLabel(item.kind, item.starts_on, item.ends_on, today);
}

/** The plan's one notification, and its Live Activity's alert. */
export function planAlertBody(item: Pick<ActivityItem, "venue" | "area" | "plan_time">): string {
  const time = planClock(item.plan_time);
  const lead = time ? `Going at ${time}` : "Going today";
  const place = activityPlace(item);
  return place ? `${lead} · ${place}` : lead;
}

/** The start push. `attributes` and `content-state` mirror the app's
 * `DayActivityAttributes` field for field; the alert is required for a
 * push-to-start, and makes the reminder's sound since it replaces the
 * reminder push on that phone. `hours` is new in build 93: older builds
 * ignore the key. A plan brings its own label and alert line. */
export function startAps(
  item: ActivityItem,
  today: string,
  endsAt: Date,
  hours: string | null = null,
  plan = false,
): Record<string, unknown> {
  const label = plan ? planLabel(item, today) : activityLabel(item.kind, item.starts_on, item.ends_on, today);
  const place = activityPlace(item);
  const body = plan ? planAlertBody(item) : place ? `${label} · ${place}` : label;
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
    "content-state": hours ? { label, hours } : { label },
    "attributes-type": "DayActivityAttributes",
    attributes,
    "stale-date": end,
    alert: { title: item.title, body, sound: "default" },
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

export async function runActivities(
  db: Db,
  groupId: string,
  at: Date,
  startedOn: StartedOn = new Map(),
): Promise<ActivityResult> {
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

  /** Sends the end to every phone running this save's activity. */
  const endOn = async (itemId: string, label: string, dismissAt: Date) => {
    const { data: tokens, error: tokensError } = await db
      .from("live_activity_tokens").select("token").eq("item_id", itemId);
    if (tokensError) throw tokensError;
    for (const { token } of (tokens ?? []) as { token: string }[]) {
      tally(await send(token, {
        event: "end",
        "content-state": { label },
        "dismissal-date": Math.floor(dismissAt.getTime() / 1000),
      }));
    }
    await db.from("live_activity_tokens").delete().eq("item_id", itemId);
  };

  // End: its time is within a tick (dismissed at that time), or the save
  // is no longer on the reminder or plan it started for (dismissed now).
  // A plan's run is forgotten rather than closed, so a moved plan can
  // start again today.
  const { data: open, error: openError } = await db
    .from("live_activity_runs")
    .select("item_id, remind_at, ends_at, source, plan_time")
    .eq("group_id", groupId)
    .is("ended_at", null);
  if (openError) throw openError;
  const runs = (open ?? []) as {
    item_id: string;
    remind_at: string;
    ends_at: string | null;
    source: string | null;
    plan_time: string | null;
  }[];
  if (runs.length) {
    // A failed read here would look like every save had gone.
    const { data: rows, error: rowsError } = await db
      .from("items")
      .select("id, kind, starts_on, ends_on, status, deleted_at, remind_at, plan_on, plan_time")
      .in("id", runs.map((r) => r.item_id));
    if (rowsError) throw rowsError;
    const byId = new Map((rows ?? []).map((r: { id: string }) => [r.id, r]));
    for (const run of runs) {
      const item = byId.get(run.item_id) as
        | {
          kind: string;
          starts_on: string | null;
          ends_on: string | null;
          status: string;
          deleted_at: string | null;
          remind_at: string | null;
          plan_on: string | null;
          plan_time: string | null;
        }
        | undefined;
      const plan = run.source === "plan";
      const endsAt = run.ends_at ? new Date(run.ends_at) : at;
      const pastDay = run.remind_at < today;
      const moved = plan
        ? item?.plan_on !== run.remind_at || planClock(item?.plan_time) !== planClock(run.plan_time)
        : item?.remind_at !== run.remind_at;
      const gone = !item || item.deleted_at != null || item.status !== "saved" || moved;
      const nearlyOver = endsAt.getTime() - at.getTime() <= TICK_MS;
      if (!pastDay && !gone && !nearlyOver) continue;

      const dismissAt = gone || pastDay || endsAt <= at ? at : endsAt;
      const label = !item
        ? "Today"
        : plan
        ? planLabel({ ...item, plan_time: run.plan_time }, run.remind_at)
        : activityLabel(item.kind, item.starts_on, item.ends_on, run.remind_at);
      await endOn(run.item_id, label, dismissAt);
      if (plan && gone && !pastDay) {
        await db.from("live_activity_runs").delete()
          .eq("item_id", run.item_id)
          .eq("remind_at", run.remind_at);
      } else {
        await db.from("live_activity_runs")
          .update({ ended_at: new Date().toISOString() })
          .eq("item_id", run.item_id)
          .eq("remind_at", run.remind_at);
      }
      result.ended++;
    }
  }

  // Start: each day-of reminder, and each plan, whose moment has come,
  // once. A plan today takes the place of the day's reminder.
  const { data: dueRows, error } = await db
    .from("items")
    .select("id, kind, title, venue, area, color, image_url, starts_on, ends_on, reminder_offset_days, reminder_anchor, remind_at, remind_time, category, address, place_id, plan_on, plan_time")
    .eq("group_id", groupId)
    .or(`remind_at.eq.${today},plan_on.eq.${today}`)
    .eq("status", "saved")
    .is("deleted_at", null);
  if (error) throw error;
  const due = ((dueRows ?? []) as ActivityItem[]).flatMap((item) => {
    if (item.plan_on === today) return planDue(item, today, clock) ? [{ item, plan: true }] : [];
    return item.remind_at === today && startDue(item, clock) ? [{ item, plan: false }] : [];
  });
  if (!due.length) return result;

  const { data: members, error: membersError } = await db
    .from("group_members").select("user_id").eq("group_id", groupId);
  if (membersError) throw membersError;
  const userIds = (members ?? []).map((m: { user_id: string }) => m.user_id);
  if (!userIds.length) return result;
  const { data: tokenRows, error: tokenError } = await db
    .from("activity_tokens").select("token, user_id, device_id").in("user_id", userIds);
  if (tokenError) throw tokenError;
  const tokens = (tokenRows ?? []) as { token: string; user_id: string; device_id: string }[];
  if (!tokens.length) return result;

  const { data: startedRows, error: startedError } = await db
    .from("live_activity_runs")
    .select("item_id, source, plan_time, ended_at")
    .eq("remind_at", today)
    .in("item_id", due.map(({ item }) => item.id));
  if (startedError) throw startedError;
  const started = new Map(
    ((startedRows ?? []) as { item_id: string; source: string | null; plan_time: string | null; ended_at: string | null }[])
      .map((r) => [r.item_id, r]),
  );

  for (const { item, plan } of due) {
    const run = started.get(item.id);
    if (run && !plan) continue;
    if (run && plan) {
      // This plan's own: already on screen, or over for the day.
      if (run.source === "plan" && planClock(run.plan_time) === planClock(item.plan_time)) continue;
      // The morning's reminder, or a plan since moved: clear it away first.
      if (!run.ended_at) {
        await endOn(item.id, activityLabel(item.kind, item.starts_on, item.ends_on, today), at);
        result.ended++;
      }
      await db.from("live_activity_runs").delete().eq("item_id", item.id).eq("remind_at", today);
    }
    const planTime = plan ? planClock(item.plan_time) : null;
    const claimEnd = activityEnd(home.timezone, today, at);
    const { error: claim } = await db
      .from("live_activity_runs")
      .insert({
        item_id: item.id,
        remind_at: today,
        group_id: groupId,
        ends_at: claimEnd.toISOString(),
        source: plan ? "plan" : "reminder",
        plan_time: planTime,
      });
    // A twin cron hit already claimed it.
    if (claim?.code === "23505") continue;
    if (claim) throw claim;
    const hours = await activityHours(item, today, at);
    const endsAt = plan ? planEnd(home.timezone, today, at, planTime, closingTime(hours, planTime, at)) : claimEnd;
    if (plan) {
      // Too close to its end to be worth putting up: done for the day.
      if (endsAt.getTime() - at.getTime() <= TICK_MS) {
        await db.from("live_activity_runs")
          .update({ ended_at: new Date().toISOString(), ends_at: endsAt.toISOString() })
          .eq("item_id", item.id).eq("remind_at", today);
        continue;
      }
      await db.from("live_activity_runs")
        .update({ ends_at: endsAt.toISOString() })
        .eq("item_id", item.id).eq("remind_at", today);
    }
    const aps = startAps(item, today, endsAt, hoursLineAt(hours, at), plan);
    let failed = 0;
    const reached = new Set<string>();
    for (const { token, user_id, device_id } of tokens) {
      const r = await send(token, aps, endsAt);
      tally(r);
      if (r === "sent") reached.add(deviceKey(user_id, device_id));
      if (r === "gone") await db.from("activity_tokens").delete().eq("token", token);
      if (r === "failed") failed++;
    }
    if (reached.size) startedOn.set(item.id, reached);
    // Nobody got it: let the next tick start it instead.
    if (failed === tokens.length) {
      await db.from("live_activity_runs").delete().eq("item_id", item.id).eq("remind_at", today);
    } else {
      result.started++;
    }
  }
  return result;
}
