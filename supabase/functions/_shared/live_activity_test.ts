import {
  activityEnd,
  activityLabel,
  activityPlace,
  alertTokens,
  closingTime,
  deviceKey,
  isDayOf,
  planAlertBody,
  planDue,
  planEnd,
  planLabel,
  startAps,
  startDue,
} from "./live_activity.ts";
import type { Hours } from "./hours.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

const today = "2026-09-24";

Deno.test("activityLabel reads the day against the save's dates", () => {
  const cases: [string, string | null, string | null, string][] = [
    ["event", today, today, "On today"],
    ["event", today, null, "On today"],
    ["event", "2026-09-01", today, "Last day"],
    ["event", today, "2026-10-30", "Opens today"],
    ["event", "2026-09-25", "2026-10-30", "Opens tomorrow"],
    ["event", "2026-09-27", null, "Opens in 3 days"],
    ["event", "2026-09-01", "2026-10-01", "Closes in 7 days"],
    ["event", "2026-09-01", "2026-10-02", "On until 2 Oct"],
    ["event", "2026-09-01", "2027-01-10", "On until 10 Jan"],
    ["event", "2026-09-01", "2026-09-25", "Closes tomorrow"],
    ["event", null, null, "Today"],
    ["place", null, null, "Today"],
  ];
  for (const [kind, starts, ends, want] of cases) {
    const got = activityLabel(kind, starts, ends, today);
    assert(got === want, `${kind} ${starts}–${ends}: ${got} ≠ ${want}`);
  }
});

Deno.test("activityPlace joins what's there", () => {
  assert(activityPlace({ venue: "Hayward Gallery", area: "South Bank" }) === "Hayward Gallery · South Bank", "both");
  assert(activityPlace({ venue: " ", area: "Soho" }) === "Soho", "blank venue");
  assert(activityPlace({ venue: null, area: null }) === null, "none");
});

Deno.test("only day-of reminders, from the moment they go off", () => {
  const morningOf = { reminder_offset_days: 0, reminder_anchor: "ends_on", remind_time: null };
  const weekBefore = { reminder_offset_days: 7, reminder_anchor: "ends_on", remind_time: null };
  const picked = { reminder_offset_days: 0, reminder_anchor: "custom", remind_time: "17:30:00" };
  const at = (hour: string, minute = "00") => ({ hour, minute });

  assert(isDayOf(morningOf) && isDayOf(picked) && !isDayOf(weekBefore), "day-of");
  assert(!startDue(morningOf, at("09", "45")) && startDue(morningOf, at("10")), "preset at 10:00");
  assert(!startDue(weekBefore, at("10")), "a week before stays a notification");
  assert(!startDue(picked, at("17", "15")) && startDue(picked, at("17", "30")), "picked time");
  assert(!startDue(picked, at("23", "05")), "nothing starts after 23:00");
});

Deno.test("activityEnd: eight hours on, or midnight at home", () => {
  const morning = activityEnd("Europe/London", today, new Date("2026-09-24T09:00:00Z"));
  assert(morning.toISOString() === "2026-09-24T17:00:00.000Z", `10:00 BST → 18:00: ${morning.toISOString()}`);
  const evening = activityEnd("Europe/London", today, new Date("2026-09-24T16:30:00Z"));
  assert(evening.toISOString() === "2026-09-24T23:00:00.000Z", `17:30 BST → midnight: ${evening.toISOString()}`);
});

Deno.test("a phone the Live Activity reached skips the reminder alert; every other phone gets it", () => {
  const devices = [
    { token: "can-iphone", user_id: "can", device_id: "phone-1" },
    { token: "can-ipad", user_id: "can", device_id: "pad-1" },
    { token: "joyce-iphone", user_id: "joyce", device_id: "phone-2" },
    { token: "legacy", user_id: "joyce", device_id: null },
  ];
  const startedOn = new Map([["save-1", new Set([deviceKey("can", "phone-1"), deviceKey("joyce", "phone-2")])]]);
  assert(
    JSON.stringify(alertTokens(devices, "save-1", startedOn)) === JSON.stringify(["can-ipad", "legacy"]),
    "reached phones skip; the rest and unmatched tokens get it",
  );
  assert(alertTokens(devices, "save-2", startedOn).length === 4, "another save: everyone");
  assert(alertTokens(devices, "save-1", new Map()).length === 4, "no activity started: everyone");
  // Same device id under another account (a shared iPad) is not the same phone.
  const other = new Map([["save-1", new Set([deviceKey("sam", "pad-1")])]]);
  assert(alertTokens(devices, "save-1", other).length === 4, "account and device both match");
});

Deno.test("startAps matches DayActivityAttributes and sounds like the reminder it replaces", () => {
  const endsAt = new Date("2026-09-24T17:00:00Z");
  const aps = startAps({
    id: "3f1c0a52-0000-4000-8000-000000000001",
    kind: "event",
    title: "Anish Kapoor",
    venue: "Hayward Gallery",
    area: null,
    color: null,
    image_url: "https://example.org/kapoor.jpg",
    starts_on: "2026-09-01",
    ends_on: today,
    reminder_offset_days: 0,
    reminder_anchor: "ends_on",
    remind_time: null,
  }, today, endsAt);
  assert(aps.event === "start", "event");
  assert(aps["attributes-type"] === "DayActivityAttributes", "type name");
  const attributes = aps.attributes as Record<string, unknown>;
  assert(attributes.itemID === "3f1c0a52-0000-4000-8000-000000000001", "id");
  assert(attributes.day === today && attributes.endsAt === 1790269200, JSON.stringify(attributes));
  assert(attributes.place === "Hayward Gallery" && !("colorHex" in attributes), "optional fields");
  assert(attributes.imageURL === "https://example.org/kapoor.jpg", "photo");
  assert(JSON.stringify(aps["content-state"]) === JSON.stringify({ label: "Last day" }), "state");
  const alert = aps.alert as Record<string, unknown>;
  assert(alert.body === "Last day · Hayward Gallery" && alert.sound === "default" && !("sound" in aps), "alert sound");
  assert(aps["stale-date"] === 1790269200, "stale at the end");
});

Deno.test("startAps carries today's hours only when there are some", () => {
  const item = {
    id: "3f1c0a52-0000-4000-8000-000000000002",
    kind: "place",
    title: "Charleston",
    venue: null,
    area: null,
    color: null,
    image_url: null,
    starts_on: null,
    ends_on: null,
    reminder_offset_days: 0,
    reminder_anchor: null,
    remind_time: null,
  };
  const endsAt = new Date("2026-09-24T17:00:00Z");
  const withHours = startAps(item, today, endsAt, "Open until 17:00");
  assert(
    JSON.stringify(withHours["content-state"]) === JSON.stringify({ label: "Today", hours: "Open until 17:00" }),
    JSON.stringify(withHours["content-state"]),
  );
  const without = startAps(item, today, endsAt, null);
  assert(!("hours" in (without["content-state"] as Record<string, unknown>)), "no key without hours");
});

const at = (hour: string, minute = "00") => ({ hour, minute });

Deno.test("a plan goes up an hour before its time, or at 10:00 without one", () => {
  const timed = { plan_on: today, plan_time: "17:00:00" };
  const day = { plan_on: today, plan_time: null };
  assert(!planDue(timed, today, at("15", "45")) && planDue(timed, today, at("16")), "an hour before");
  assert(planDue(timed, today, at("23", "30")), "a late plan still goes up");
  assert(!planDue({ plan_on: "2026-09-25", plan_time: "17:00" }, today, at("16")), "another day");
  assert(!planDue(day, today, at("09", "45")) && planDue(day, today, at("10")), "10:00 without a time");
  assert(!planDue(day, today, at("23", "05")), "nothing starts after 23:00 without a time");
  assert(planDue({ plan_on: today, plan_time: "00:30:00" }, today, at("00", "00")), "just after midnight");
});

const hayward: Hours = {
  status: "open",
  days: [{ date: today, ranges: [{ open: "10:00", close: "18:00" }] }],
  offset: 60,
};

Deno.test("closingTime: the opening the plan falls in, while it's still ahead", () => {
  const now = new Date("2026-09-24T12:00:00Z"); // 13:00 BST
  assert(closingTime(hayward, "15:00", now)?.toISOString() === "2026-09-24T17:00:00.000Z", "18:00 BST");
  assert(closingTime(hayward, "19:00", now) === null, "a time after closing isn't cut short");
  assert(closingTime(hayward, null, now)?.toISOString() === "2026-09-24T17:00:00.000Z", "no time: the day's close");
  assert(closingTime(hayward, null, new Date("2026-09-24T17:30:00Z")) === null, "already closed");
  const split: Hours = {
    ...hayward,
    days: [{ date: today, ranges: [{ open: "12:00", close: "15:00" }, { open: "18:00", close: "23:00" }] }],
  };
  assert(closingTime(split, "19:30", now)?.toISOString() === "2026-09-24T22:00:00.000Z", "the evening sitting");
  const late: Hours = { ...hayward, days: [{ date: today, ranges: [{ open: "18:00", close: "02:00" }] }] };
  assert(closingTime(late, "20:00", now) === null, "past midnight is the midnight cap's");
  assert(closingTime({ ...hayward, days: [{ date: today, ranges: [] }] }, "15:00", now) === null, "closed today");
  assert(closingTime(null, "15:00", now) === null, "no hours");
});

Deno.test("planEnd: closing, four hours after, midnight, or eight hours — the earliest", () => {
  const tz = "Europe/London";
  const four = new Date("2026-09-24T15:00:00Z"); // 16:00 BST, an hour before 17:00
  assert(planEnd(tz, today, four, "17:00", null).toISOString() === "2026-09-24T20:00:00.000Z", "21:00: four hours after");
  const closes = new Date("2026-09-24T17:00:00Z");
  assert(planEnd(tz, today, four, "17:00", closes).toISOString() === closes.toISOString(), "closing first");
  const late = new Date("2026-09-24T20:00:00Z"); // 21:00 BST
  assert(planEnd(tz, today, late, "22:00", null).toISOString() === "2026-09-24T23:00:00.000Z", "midnight caps");
  const morning = new Date("2026-09-24T09:00:00Z"); // 10:00 BST
  assert(planEnd(tz, today, morning, null, null).toISOString() === "2026-09-24T17:00:00.000Z", "no time: eight hours");
});

Deno.test("a plan's label and alert say when", () => {
  const item = { kind: "event", starts_on: "2026-09-01", ends_on: today, venue: "Hayward Gallery", area: "South Bank" };
  assert(planLabel({ plan_time: "17:00:00" }) === "Going 17:00", "timed label");
  assert(planLabel({ plan_time: null }) === "Planned for today", "untimed label");
  assert(planAlertBody({ ...item, plan_time: "17:00:00" }) === "Going at 17:00 · Hayward Gallery · South Bank", "timed alert");
  assert(planAlertBody({ venue: null, area: null, plan_time: null }) === "Going today", "untimed alert");
});

Deno.test("startAps for a plan carries its label and alert", () => {
  const aps = startAps({
    id: "3f1c0a52-0000-4000-8000-000000000003",
    kind: "event",
    title: "Anish Kapoor",
    venue: "Hayward Gallery",
    area: null,
    color: null,
    image_url: null,
    starts_on: "2026-09-01",
    ends_on: "2026-10-30",
    reminder_offset_days: null,
    reminder_anchor: null,
    remind_time: null,
    plan_on: today,
    plan_time: "17:00:00",
  }, today, new Date("2026-09-24T17:00:00Z"), "Open until 18:00", true);
  assert(
    JSON.stringify(aps["content-state"]) === JSON.stringify({ label: "Going 17:00", hours: "Open until 18:00" }),
    JSON.stringify(aps["content-state"]),
  );
  assert((aps.alert as Record<string, unknown>).body === "Going at 17:00 · Hayward Gallery", "alert");
});
