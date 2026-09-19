import { customReminderBody, customTimeDue, reminderBody } from "./reminders.ts";

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

Deno.test("customReminderBody: places are a plain nudge, no you/your", () => {
  const body = customReminderBody("place", "Borough Market", "2026-12-15", null, null);
  assert(body === "Reminder to go to Borough Market.", body);
  assert(!/\byour?\b/i.test(body), "neutral for one or two people");
  assert(customReminderBody("place", "  ", "2026-12-15", null, null) === "Reminder to go to this one.", "blank title");
});

Deno.test("customReminderBody: events say where the date sits", () => {
  assert(
    customReminderBody("event", "Lates", "2026-12-15", "2026-12-16", "2026-12-16") === "Reminder: Lates opens tomorrow.",
    "day before",
  );
  assert(
    customReminderBody("event", "Lates", "2026-12-15", "2026-12-22", "2027-01-10") === "Reminder: Lates opens in a week.",
    "week before",
  );
  assert(
    customReminderBody("event", "Lates", "2026-12-15", "2026-12-18", null) === "Reminder: Lates opens in 3 days.",
    "3 days before, open-ended",
  );
  assert(
    customReminderBody("event", "Lates", "2026-12-15", "2026-12-15", "2026-12-15") === "Reminder: Lates is on today.",
    "one-day event, on the day",
  );
  assert(
    customReminderBody("event", "Lates", "2026-12-15", "2026-12-01", "2026-12-15") === "Reminder: last day for Lates.",
    "closes today",
  );
  assert(
    customReminderBody("event", "Lates", "2026-12-15", "2026-12-01", "2026-12-16") === "Reminder: Lates closes tomorrow.",
    "running, closes tomorrow",
  );
  assert(
    customReminderBody("event", "Lates", "2026-12-15", null, null) === "Reminder to go to Lates.",
    "undated event falls back to the nudge",
  );
  assert(
    customReminderBody("event", "Lates", "2026-12-15", "2026-12-01", "2026-12-10") === "Reminder to go to Lates.",
    "already over: still just a nudge",
  );
});

Deno.test("customTimeDue: fires once the home clock passes the time", () => {
  assert(customTimeDue("18:30", { hour: "18", minute: "30" }), "on the minute");
  assert(customTimeDue("18:30:00", { hour: "18", minute: "44" }), "Postgres seconds, later pass");
  assert(!customTimeDue("18:30", { hour: "18", minute: "15" }), "not yet");
  assert(!customTimeDue("09:00", { hour: "08", minute: "59" }), "zero-padded compare");
});
