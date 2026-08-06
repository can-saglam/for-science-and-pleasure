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

function dayDiff(from: string, to: string): number {
  return Math.round(
    (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000,
  );
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
 * One line per relevant event, ordered: closing soonest, one-offs,
 * openings. Same date rules as the app's This Week tab.
 */
export function buildDigest(
  items: DigestItem[],
  today = new Date().toISOString().slice(0, 10),
): string {
  const events = items.filter((i) => i.kind === "event");

  const oneOffs = events
    .filter(
      (i) =>
        i.starts_on &&
        i.starts_on === i.ends_on &&
        dayDiff(today, i.starts_on) >= 0 &&
        dayDiff(today, i.starts_on) <= 7,
    )
    .sort((a, b) => a.starts_on!.localeCompare(b.starts_on!));
  const oneOffIds = new Set(oneOffs.map((i) => i.id));

  const closing = events
    .filter(
      (i) =>
        !oneOffIds.has(i.id) &&
        i.ends_on &&
        dayDiff(today, i.ends_on) >= 0 &&
        dayDiff(today, i.ends_on) <= 7 &&
        (!i.starts_on || dayDiff(today, i.starts_on) <= 0),
    )
    .sort((a, b) => a.ends_on!.localeCompare(b.ends_on!));

  const opening = events
    .filter(
      (i) =>
        !oneOffIds.has(i.id) &&
        i.starts_on &&
        dayDiff(today, i.starts_on) > 0 &&
        dayDiff(today, i.starts_on) <= 7,
    )
    .sort((a, b) => a.starts_on!.localeCompare(b.starts_on!));

  const lines = [
    ...closing.map((i) => line(`Closes ${fmtDay(i.ends_on!)}`, i)),
    ...oneOffs.map((i) => line(`One-off ${fmtDay(i.starts_on!)}`, i)),
    ...opening.map((i) => line(`Opens ${fmtDay(i.starts_on!)}`, i)),
  ];

  if (lines.length === 0) return "Nothing pressing this week.";
  if (lines.length > 8) {
    return [...lines.slice(0, 7), `+${lines.length - 7} more in the app`].join("\n");
  }
  return lines.join("\n");
}
