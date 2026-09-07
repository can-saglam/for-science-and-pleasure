// Digest scheduling arithmetic, kept free of I/O so it can be unit-tested.
// Used by send-digest; mirrors the SQL in dispatch_weekly_digest().

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
 * Inside the send window: the right weekday, and between the scheduled
 * minute and 59 minutes after it (the dispatcher pings every 15 minutes,
 * so one of its pings always lands in the hour; digest_runs dedups).
 */
export function isDue(sched: Pick<Schedule, "day_of_week" | "hour" | "minute">, clock: LocalClock): boolean {
  if (ISO_DOW[clock.weekday] !== sched.day_of_week) return false;
  const now = Number(clock.hour) * 60 + Number(clock.minute);
  const start = sched.hour * 60 + sched.minute;
  return now >= start && now <= start + 59;
}

/** ISO Monday of the week containing `date` (YYYY-MM-DD). The digest_runs key. */
export function weekMonday(date: string): string {
  const d = new Date(`${date}T00:00:00Z`);
  const offset = (d.getUTCDay() + 6) % 7; // Mon=0 … Sun=6
  d.setUTCDate(d.getUTCDate() - offset);
  return d.toISOString().slice(0, 10);
}
