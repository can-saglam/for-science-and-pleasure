import { reminderBody } from "./reminders.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

Deno.test("reminderBody: one-day event", () => {
  assert(reminderBody(0, "starts_on", "2026-12-22", "2026-12-22") === "Today", "morning of");
  assert(reminderBody(1, "starts_on", "2026-12-22", "2026-12-22") === "Tomorrow", "day before");
  assert(reminderBody(3, "starts_on", "2026-12-22", "2026-12-22") === "In 3 days", "3 days");
  assert(reminderBody(7, "starts_on", "2026-12-22", "2026-12-22") === "In a week", "week");
});

Deno.test("reminderBody: range — opens vs closes", () => {
  assert(reminderBody(7, "starts_on", "2026-12-22", "2027-01-10") === "Opens in a week", "week before start");
  assert(reminderBody(1, "ends_on", "2026-12-22", "2027-01-10") === "Closes tomorrow", "day before close");
  assert(reminderBody(0, "ends_on", "2026-12-22", "2027-01-10") === "Today", "morning of close");
  assert(reminderBody(3, "starts_on", "2026-12-22", "2027-01-10") === "Opens in 3 days", "3 days before start");
});
