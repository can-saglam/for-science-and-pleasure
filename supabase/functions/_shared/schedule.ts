// Home-clock arithmetic, kept free of I/O so it can be unit-tested.
// Used by send-reminders (10:00 home hour).

export interface Schedule {
  group_id: string;
  day_of_week: number; // ISO: Mon = 1 … Sun = 7
  hour: number;
  minute: number;
  timezone: string;
}

export interface LocalClock {
  weekday: string; // "Mon" … "Sun"
  year: string;
  month: string;
  day: string;
  hour: string;
  minute: string;
}

const ISO_DOW: Record<string, number> = {
  Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7,
};

/** Wall-clock parts for `at` in `timeZone`; a bad zone falls back to London. */
export function localClock(timeZone: string, at: Date = new Date()): LocalClock {
  let parts;
  try {
    parts = new Intl.DateTimeFormat("en-GB", {
      timeZone,
      weekday: "short",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(at);
  } catch {
    return localClock("Europe/London", at);
  }
  return Object.fromEntries(parts.map(({ type, value }) => [type, value])) as unknown as LocalClock;
}

export function localDate(clock: LocalClock): string {
  return `${clock.year}-${clock.month}-${clock.day}`;
}

/**
 * Inside a scheduled window: the right weekday, and between the scheduled
 * minute and 59 minutes after it (the dispatcher pings every 15 minutes,
 * so one of its pings always lands in the hour).
 */
export function isDue(sched: Pick<Schedule, "day_of_week" | "hour" | "minute">, clock: LocalClock): boolean {
  if (ISO_DOW[clock.weekday] !== sched.day_of_week) return false;
  const now = Number(clock.hour) * 60 + Number(clock.minute);
  const start = sched.hour * 60 + sched.minute;
  return now >= start && now <= start + 59;
}

/**
 * The instant `hour`:00 falls on `date` (YYYY-MM-DD) in `timeZone`, e.g.
 * 18:00 in London on a BST day is 17:00 UTC. Two passes so a day when the
 * clocks change still lands on the hour.
 */
export function homeInstant(timeZone: string, date: string, hour: number): Date {
  const [y, m, d] = date.split("-").map(Number);
  const wall = Date.UTC(y, m - 1, d, hour);
  let guess = wall;
  for (let i = 0; i < 2; i++) {
    const c = localClock(timeZone, new Date(guess));
    const shown = Date.UTC(Number(c.year), Number(c.month) - 1, Number(c.day), Number(c.hour), Number(c.minute));
    guess += wall - shown;
  }
  return new Date(guess);
}

/** The calendar day before `date` (YYYY-MM-DD). */
export function dayBefore(date: string): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

/** Fixed 10:00–10:59 home hour — when shared reminders fire. */
export function isMorningHour(clock: LocalClock, hour = 10): boolean {
  const now = Number(clock.hour) * 60 + Number(clock.minute);
  const start = hour * 60;
  return now >= start && now <= start + 59;
}

/** ISO Monday of the week containing `date` (YYYY-MM-DD). The digest_runs key. */
export function weekMonday(date: string): string {
  const d = new Date(`${date}T00:00:00Z`);
  const offset = (d.getUTCDay() + 6) % 7; // Mon=0 … Sun=6
  d.setUTCDate(d.getUTCDate() - offset);
  return d.toISOString().slice(0, 10);
}
