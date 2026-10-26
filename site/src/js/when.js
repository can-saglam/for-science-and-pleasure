// When a shared save is on, in the app's voice: "On now · until Fri 7 Nov",
// "Opens Sat 1 Nov", "Last day today". Used by the page and, on Cloudflare,
// by functions/ for the link preview and the calendar file.

const DAY_MS = 86_400_000;
const utc = (iso) => Date.UTC(+iso.slice(0, 4), +iso.slice(5, 7) - 1, +iso.slice(8, 10));
const between = (from, to) => Math.round((utc(to) - utc(from)) / DAY_MS);

/** Today where the reader is, as YYYY-MM-DD. */
export function today(now = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/** "Fri 7 Nov", with the year only when it isn't this one. */
export function dayLabel(iso, now = new Date()) {
  const label = new Intl.DateTimeFormat("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  }).format(new Date(utc(iso)));
  // Added by hand: with a year, en-GB puts a comma after the weekday.
  return iso.slice(0, 4) === today(now).slice(0, 4) ? label : `${label} ${iso.slice(0, 4)}`;
}

/** { text, urgent, over } or null when the save has no dates. */
export function when(card, now = new Date()) {
  const from = card.starts_on ?? null;
  const to = card.ends_on ?? null;
  if (!from && !to) return null;
  const now_ = today(now);
  const label = (iso) => dayLabel(iso, now);

  if (!to || from === to || !from) {
    const day = from ?? to;
    const d = between(now_, day);
    if (!from) {
      if (d < 0) return { text: `Ended ${label(to)}`, over: true };
      if (d === 0) return { text: "Last day today", urgent: true };
      return { text: `On now · until ${label(to)}`, urgent: d <= 2 };
    }
    if (d < 0) return { text: `Was on ${label(day)}`, over: true };
    if (d === 0) return { text: "Today", urgent: true };
    if (d === 1) return { text: `Tomorrow, ${label(day)}` };
    return { text: label(day) };
  }

  const toStart = between(now_, from);
  const toEnd = between(now_, to);
  if (toEnd < 0) return { text: `Ended ${label(to)}`, over: true };
  if (toStart > 0) return { text: `Opens ${label(from)} · until ${label(to)}` };
  if (toEnd === 0) return { text: "Last day today", urgent: true };
  if (toEnd === 1) return { text: "On now · last day tomorrow", urgent: true };
  return { text: `On now · until ${label(to)}`, urgent: toEnd <= 2 };
}

/** "Goodman Gallery · Mayfair" */
export function where(card) {
  return [card.venue, card.area].filter(Boolean).join(" · ");
}
