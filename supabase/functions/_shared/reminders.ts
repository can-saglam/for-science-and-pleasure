// Copy for a shared reminder push. I/O-free so the wording can be
// unit-tested next to the schedule arithmetic.
//
// Presets (a week / 3 days / 1 day / morning of) put the save's title in
// the push title and a short relative line in the body. Hand-picked
// reminders go the other way round — "Reminder" up top, the title in the
// sentence — so a place reads as a nudge rather than a countdown. Every
// line works whether one person or two get it: no "you", no "your".

export function reminderBody(
  offsetDays: number,
  anchor: string,
  startsOn: string | null,
  endsOn: string | null,
): string {
  const oneDay = startsOn != null && endsOn != null && startsOn === endsOn;
  if (offsetDays === 0) return "Today";
  if (oneDay) {
    if (offsetDays === 1) return "Tomorrow";
    if (offsetDays === 3) return "In 3 days";
    if (offsetDays === 7) return "In a week";
    return "Coming up";
  }
  const verb = anchor === "ends_on" ? "Closes" : "Opens";
  if (offsetDays === 1) return `${verb} tomorrow`;
  if (offsetDays === 3) return `${verb} in 3 days`;
  if (offsetDays === 7) return `${verb} in a week`;
  return `${verb} soon`;
}

/** Whole days from `from` to `to` (YYYY-MM-DD); negative when `to` is earlier. */
function daysBetween(from: string, to: string): number {
  const a = Date.parse(`${from}T00:00:00Z`);
  const b = Date.parse(`${to}T00:00:00Z`);
  return Math.round((b - a) / 86_400_000);
}

function inDays(n: number): string {
  if (n === 1) return "tomorrow";
  if (n === 7) return "in a week";
  return `in ${n} days`;
}

/**
 * Body for a hand-picked reminder, fired on `remindAt`. Places get the
 * plain nudge. Events add where the date sits relative to the fire day,
 * when there is one to sit against.
 */
export function customReminderBody(
  kind: string,
  title: string,
  remindAt: string,
  startsOn: string | null,
  endsOn: string | null,
): string {
  const name = title.trim() || "this one";
  if (kind !== "event") return `Reminder to go to ${name}.`;

  if (startsOn && startsOn > remindAt) {
    return `Reminder: ${name} opens ${inDays(daysBetween(remindAt, startsOn))}.`;
  }
  if (startsOn && startsOn === remindAt) {
    return `Reminder: ${name} is on today.`;
  }
  if (endsOn && endsOn === remindAt) {
    return `Reminder: last day for ${name}.`;
  }
  if (endsOn && endsOn > remindAt) {
    return `Reminder: ${name} closes ${inDays(daysBetween(remindAt, endsOn))}.`;
  }
  return `Reminder to go to ${name}.`;
}

/** Push title for a hand-picked reminder. */
export const CUSTOM_REMINDER_TITLE = "Reminder";

/**
 * A hand-picked time (HH:MM or Postgres HH:MM:SS, home clock) has come
 * round on the group's local clock.
 */
export function customTimeDue(remindTime: string, clock: { hour: string; minute: string }): boolean {
  return remindTime.slice(0, 5) <= `${clock.hour}:${clock.minute}`;
}
