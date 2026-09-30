// Opening hours, from Google, for the place a save is at. Asked for each
// time they're shown: Google's terms let us keep a place ID but not its
// hours. Only where the venue's hours are the save's: places (not concert
// halls and the like, whose hours are the box office's), and exhibitions
// and markets that run for days rather than a night.
import { sameName } from "./places.ts";
import { ukPostcode } from "./home.ts";

const API = "https://places.googleapis.com/v1";

export interface HoursSubject {
  kind: string;
  category: string | null;
  starts_on: string | null;
  ends_on: string | null;
}

/** Runs of at least this many days (end minus start) get hours. */
export const MIN_RUN_DAYS = 3;

export function hoursApply(item: HoursSubject): boolean {
  if (item.kind === "place") return item.category !== "venue";
  if (item.kind !== "event") return false;
  if (item.category !== "exhibition" && item.category !== "market") return false;
  if (!item.starts_on || !item.ends_on) return true;
  const days = (Date.parse(`${item.ends_on}T00:00:00Z`) - Date.parse(`${item.starts_on}T00:00:00Z`)) / 86_400_000;
  return days >= MIN_RUN_DAYS;
}

/** Hours worth showing `today` (yyyy-MM-dd, home clock): an event's only
 * while it's on. Before it opens, the venue's hours are no use yet. */
export function hoursShown(item: HoursSubject, today: string): boolean {
  if (!hoursApply(item)) return false;
  if (item.kind !== "event") return true;
  return (!item.starts_on || item.starts_on <= today) && (!item.ends_on || item.ends_on >= today);
}

/** Hours worth having while picking a day to go: an event's before it
 * opens too, so its closed days can be marked. */
export function hoursForPlanning(item: HoursSubject, today: string): boolean {
  if (!hoursApply(item)) return false;
  return item.kind !== "event" || !item.ends_on || item.ends_on >= today;
}

/** "HH:MM" on the venue's clock. A close of "24:00" is midnight. */
export interface Range {
  open: string;
  close: string;
}

export interface Day {
  /** yyyy-MM-dd on the venue's clock. */
  date: string;
  ranges: Range[];
}

export interface Hours {
  status: "open" | "closed_temporarily" | "closed_permanently";
  /** Seven days, today (on the venue's clock) first. Empty when closed. */
  days: Day[];
  /** The venue's offset from UTC right now, in minutes. */
  offset: number;
}

interface Point {
  day?: number;
  hour?: number;
  minute?: number;
  date?: { year: number; month: number; day: number };
}

export interface Period {
  open?: Point;
  close?: Point;
}

const pad = (n: number) => String(n).padStart(2, "0");
const clock = (p: Point) => `${pad(p.hour ?? 0)}:${pad(p.minute ?? 0)}`;

function addDays(date: string, n: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
}

/** The venue's own date: `offset` minutes from UTC. */
export function venueToday(now: Date, offset: number): string {
  return new Date(now.getTime() + offset * 60_000).toISOString().slice(0, 10);
}

/**
 * Google's periods as a week of days from `today`. Current hours carry a
 * date on each opening (holidays and one-off lates differ from the usual
 * week); regular hours only a weekday. A lone opening at Sunday 00:00
 * with no close is open around the clock.
 */
export function weekFrom(periods: Period[], today: string): Day[] {
  const always = periods.length === 1 && !periods[0].close &&
    (periods[0].open?.hour ?? 0) === 0 && (periods[0].open?.minute ?? 0) === 0;
  return Array.from({ length: 7 }, (_, i) => {
    const date = addDays(today, i);
    if (always) return { date, ranges: [{ open: "00:00", close: "24:00" }] };
    const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();
    const ranges = periods
      .filter(({ open }) => {
        if (!open) return false;
        if (open.date) return `${open.date.year}-${pad(open.date.month)}-${pad(open.date.day)}` === date;
        return open.day === weekday;
      })
      .map(({ open, close }) => ({ open: clock(open!), close: close ? clock(close) : "24:00" }))
      .sort((a, b) => a.open.localeCompare(b.open));
    return { date, ranges };
  });
}

export const minutes = (hm: string) => Number(hm.slice(0, 2)) * 60 + Number(hm.slice(3, 5));
/** A close at or before its opening runs past midnight. */
export const closeMinutes = (r: Range) => {
  const c = minutes(r.close);
  return c <= minutes(r.open) ? c + 1440 : c;
};
const shown = (hm: string) => (hm === "24:00" || hm === "00:00" ? "midnight" : hm);

/**
 * Today's hours in a few words, at `now` minutes past midnight on the
 * venue's clock, for the Live Activity. Written once when it starts and
 * on screen for hours after, so each line stays true as the day goes on.
 */
export function hoursLine(hours: Hours, now: number): string | null {
  if (hours.status === "closed_temporarily") return "Temporarily closed";
  if (hours.status === "closed_permanently") return "Closed for good";
  const today = hours.days[0];
  if (!today) return null;
  const ranges = today.ranges;
  if (!ranges.length) return "Closed today";
  if (ranges.length === 1 && ranges[0].open === "00:00" && closeMinutes(ranges[0]) >= 1440) {
    return "Open 24 hours";
  }
  if (now < minutes(ranges[0].open)) {
    return ranges.length === 1
      ? `Open ${ranges[0].open}–${shown(ranges[0].close)}`
      : `Opens ${ranges[0].open}`;
  }
  for (let i = 0; i < ranges.length; i++) {
    const r = ranges[i];
    if (now >= minutes(r.open) && now < closeMinutes(r)) return `Open until ${shown(r.close)}`;
    const next = ranges[i + 1];
    if (next && now < minutes(next.open)) return `Reopens ${next.open}`;
  }
  return "Closed for the day";
}

/** The name the hours are checked against: Google's for the place has to
 * be the save's venue (or, for a place, its title), or sit at its
 * postcode. A draft whose venue was changed before saving keeps the ID
 * the parser found for the old one; this stops those hours showing. */
export function samePlace(
  item: { title: string; venue: string | null; address?: string | null },
  found: { name: string; address: string | null },
): boolean {
  for (const name of [item.venue, item.title]) {
    if (name && sameName(name, found.name)) return true;
  }
  const saved = item.address ? ukPostcode(item.address) : null;
  return saved !== null && ukPostcode(found.address ?? "") === saved;
}

interface Details {
  displayName?: { text?: string };
  formattedAddress?: string;
  businessStatus?: string;
  utcOffsetMinutes?: number;
  currentOpeningHours?: { periods?: Period[] };
  regularOpeningHours?: { periods?: Period[] };
}

/** One Place Details call, billed at the Enterprise rate: the only one
 * that asks Google for hours. Null for no key, a miss, or no hours known. */
export async function placeHours(
  placeId: string,
  item: { title: string; venue: string | null; address?: string | null },
  now = new Date(),
  timeout = 8_000,
): Promise<Hours | null> {
  const key = Deno.env.get("GOOGLE_MAPS_API_KEY");
  if (!key || !placeId) return null;
  try {
    const res = await fetch(`${API}/places/${encodeURIComponent(placeId)}`, {
      headers: {
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask":
          "displayName,formattedAddress,businessStatus,utcOffsetMinutes,currentOpeningHours.periods,regularOpeningHours.periods",
      },
      signal: AbortSignal.timeout(timeout),
    });
    if (!res.ok) {
      console.warn("place hours", res.status, (await res.text()).slice(0, 200));
      return null;
    }
    const d = await res.json() as Details;
    if (!samePlace(item, { name: d.displayName?.text ?? "", address: d.formattedAddress ?? null })) {
      return null;
    }
    const offset = d.utcOffsetMinutes ?? 0;
    if (d.businessStatus === "CLOSED_TEMPORARILY") return { status: "closed_temporarily", days: [], offset };
    if (d.businessStatus === "CLOSED_PERMANENTLY") return { status: "closed_permanently", days: [], offset };
    const periods = d.currentOpeningHours?.periods ?? d.regularOpeningHours?.periods;
    if (!periods?.length) return null;
    return { status: "open", days: weekFrom(periods, venueToday(now, offset)), offset };
  } catch (e) {
    console.warn("place hours failed", String(e));
    return null;
  }
}
