import { activityEnd, activityLabel, activityPlace, isDayOf, startAps, startDue } from "./live_activity.ts";

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

Deno.test("startAps matches DayActivityAttributes and stays silent", () => {
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
  assert(alert.body === "Last day · Hayward Gallery" && !("sound" in alert) && !("sound" in aps), "silent alert");
  assert(aps["stale-date"] === 1790269200, "stale at the end");
});
