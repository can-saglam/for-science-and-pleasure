// Copy for a shared per-event reminder push. I/O-free so the wording can
// be unit-tested next to the schedule arithmetic.

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
