import { activityLabel, activityPlace, startAps } from "./live_activity.ts";

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
    ["event", null, null, "Reminder"],
    ["event", "2026-09-01", "2026-09-10", "Reminder"],
    ["place", null, null, "Reminder"],
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

Deno.test("startAps matches DayActivityAttributes and stays silent", () => {
  const goneAt = new Date("2026-09-24T17:00:00Z");
  const aps = startAps({
    id: "3f1c0a52-0000-4000-8000-000000000001",
    kind: "event",
    title: "Anish Kapoor",
    venue: "Hayward Gallery",
    area: null,
    color: null,
    starts_on: "2026-09-01",
    ends_on: today,
  }, today, goneAt);
  assert(aps.event === "start", "event");
  assert(aps["attributes-type"] === "DayActivityAttributes", "type name");
  const attributes = aps.attributes as Record<string, unknown>;
  assert(attributes.itemID === "3f1c0a52-0000-4000-8000-000000000001", "id");
  assert(attributes.day === today && attributes.endsAt === 1790269200, JSON.stringify(attributes));
  assert(attributes.place === "Hayward Gallery" && !("colorHex" in attributes), "optional fields");
  assert(JSON.stringify(aps["content-state"]) === JSON.stringify({ label: "Last day" }), "state");
  const alert = aps.alert as Record<string, unknown>;
  assert(alert.body === "Last day · Hayward Gallery" && !("sound" in alert) && !("sound" in aps), "silent alert");
  assert(aps["stale-date"] === 1790269200, "stale at six");
});
