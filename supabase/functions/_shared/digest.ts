// Deterministic weekly digest — a plain factual summary of the week,
// computed straight from the saved items. No LLM involved.

export interface DigestItem {
  id: string;
  kind: "event" | "place";
  status: string;
  title: string;
  venue: string | null;
  area: string | null;
  category: string | null;
  price: string | null;
  starts_on: string | null;
  ends_on: string | null;
}

function addDays(date: string, n: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** The weekend in view from `date`: the coming Fri–Sun, or the remainder
 * of the current one when it's already under way. */
export function weekendWindow(date: string): { start: string; end: string } {
  const dow = new Date(`${date}T00:00:00Z`).getUTCDay(); // 0 = Sun
  const sunday = addDays(date, (7 - dow) % 7);
  const friday = addDays(sunday, -2);
  return { start: friday < date ? date : friday, end: sunday };
}

function fmtDay(date: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  }).format(new Date(`${date}T12:00:00Z`));
}

function line(prefix: string, item: DigestItem): string {
  return `${prefix}: ${item.title}${item.venue ? ` — ${item.venue}` : ""}`;
}

/**
 * The weekend ahead (Fri + Sat + Sun), one line per relevant event:
 * what's in its final days, what's happening once, what's opening.
 */
export function buildDigest(
  items: DigestItem[],
  today = new Date().toISOString().slice(0, 10),
): string {
  const events = items.filter((i) => i.kind === "event");
  const { start, end } = weekendWindow(today);
  const inWeekend = (d: string | null) => Boolean(d && d >= start && d <= end);

  const oneOffs = events
    .filter((i) => i.starts_on && i.starts_on === i.ends_on && inWeekend(i.starts_on))
    .sort((a, b) => a.starts_on!.localeCompare(b.starts_on!));
  const oneOffIds = new Set(oneOffs.map((i) => i.id));

  // Already-running events whose window shuts over the weekend — last
  // chance. Pop-ups that only open during the weekend read as "Opens",
  // not "Closes", even if they wrap up by Sunday.
  const closing = events
    .filter(
      (i) =>
        !oneOffIds.has(i.id) &&
        inWeekend(i.ends_on) &&
        (!i.starts_on || i.starts_on < start),
    )
    .sort((a, b) => a.ends_on!.localeCompare(b.ends_on!));
  const closingIds = new Set(closing.map((i) => i.id));

  const opening = events
    .filter(
      (i) =>
        !oneOffIds.has(i.id) && !closingIds.has(i.id) && inWeekend(i.starts_on),
    )
    .sort((a, b) => a.starts_on!.localeCompare(b.starts_on!));

  const lines = [
    ...closing.map((i) => line(`Closes ${fmtDay(i.ends_on!)}`, i)),
    ...oneOffs.map((i) => line(`On ${fmtDay(i.starts_on!)}`, i)),
    ...opening.map((i) => line(`Opens ${fmtDay(i.starts_on!)}`, i)),
  ];

  if (lines.length === 0) {
    return "A quiet weekend on paper — open the app for what's still on.";
  }
  if (lines.length > 8) {
    return [...lines.slice(0, 7), `+${lines.length - 7} more in the app`].join("\n");
  }
  return lines.join("\n");
}
