import { dayBefore, homeInstant, isDue, isMorningHour, localClock, localDate, weekMonday } from "./schedule.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

Deno.test("dayBefore crosses months, years and leap days", () => {
  for (const [d, want] of [
    ["2026-09-24", "2026-09-23"],
    ["2026-10-01", "2026-09-30"],
    ["2027-01-01", "2026-12-31"],
    ["2028-03-01", "2028-02-29"],
    ["2026-10-26", "2026-10-25"],
  ]) {
    assert(dayBefore(d) === want, `${d} → ${dayBefore(d)}`);
  }
});

Deno.test("weekMonday returns the ISO Monday for every weekday", () => {
  // 2026-09-07 is a Monday.
  const expect = "2026-09-07";
  for (const d of ["2026-09-07", "2026-09-08", "2026-09-10", "2026-09-12", "2026-09-13"]) {
    assert(weekMonday(d) === expect, `${d} → ${weekMonday(d)}`);
  }
  assert(weekMonday("2026-09-14") === "2026-09-14", "next Monday is its own week");
  assert(weekMonday("2026-09-06") === "2026-08-31", "Sunday belongs to the previous Monday");
});

Deno.test("localClock: London BST vs GMT, and other zones", () => {
  // 10:00 UTC on 10 Sep 2026 is 11:00 in London (BST) and 06:00 in New York (EDT).
  const at = new Date("2026-09-10T10:00:00Z");
  const london = localClock("Europe/London", at);
  assert(london.weekday === "Thu" && london.hour === "11" && london.minute === "00", JSON.stringify(london));
  assert(localDate(london) === "2026-09-10", localDate(london));
  const ny = localClock("America/New_York", at);
  assert(ny.hour === "06", JSON.stringify(ny));
  // After the clocks go back: 10:00 UTC on 10 Dec is 10:00 in London.
  const winter = localClock("Europe/London", new Date("2026-12-10T10:00:00Z"));
  assert(winter.hour === "10", JSON.stringify(winter));
  // Crossing midnight: 23:30 UTC Thursday is Friday 08:30 in Tokyo.
  const tokyo = localClock("Asia/Tokyo", new Date("2026-09-10T23:30:00Z"));
  assert(tokyo.weekday === "Fri" && tokyo.hour === "08", JSON.stringify(tokyo));
  assert(localDate(tokyo) === "2026-09-11", "Tokyo date rolled over");
});

Deno.test("localClock: garbage timezone falls back to London instead of throwing", () => {
  const at = new Date("2026-09-10T10:00:00Z");
  const c = localClock("Mars/Olympus_Mons", at);
  assert(c.hour === "11", JSON.stringify(c));
});

Deno.test("isDue: Thursday 10:00 schedule fires only inside 10:00–10:59 Thursday", () => {
  const sched = { day_of_week: 4, hour: 10, minute: 0 };
  const clock = (weekday: string, hour: string, minute: string) => ({ weekday, hour, minute, year: "2026", month: "09", day: "10" });
  assert(isDue(sched, clock("Thu", "10", "00")), "exact minute");
  assert(isDue(sched, clock("Thu", "10", "15")), "dispatcher's next ping");
  assert(isDue(sched, clock("Thu", "10", "59")), "last minute of window");
  assert(!isDue(sched, clock("Thu", "11", "00")), "window closed");
  assert(!isDue(sched, clock("Thu", "09", "59")), "not yet");
  assert(!isDue(sched, clock("Wed", "10", "00")), "wrong day");
  assert(!isDue(sched, clock("Fri", "10", "00")), "wrong day (after)");
});

Deno.test("isMorningHour: 10:00–10:59 any weekday", () => {
  const clock = (hour: string, minute: string) => ({
    weekday: "Mon", hour, minute, year: "2026", month: "12", day: "15",
  });
  assert(isMorningHour(clock("10", "00")), "exact minute");
  assert(isMorningHour(clock("10", "15")), "dispatcher ping");
  assert(isMorningHour(clock("10", "59")), "last minute");
  assert(!isMorningHour(clock("11", "00")), "window closed");
  assert(!isMorningHour(clock("09", "59")), "not yet");
});

Deno.test("isDue: a schedule near midnight does not spill into the next day", () => {
  const sched = { day_of_week: 7, hour: 23, minute: 30 };
  const clock = (weekday: string, hour: string, minute: string) => ({ weekday, hour, minute, year: "2026", month: "09", day: "13" });
  assert(isDue(sched, clock("Sun", "23", "45")), "same day, inside window");
  assert(!isDue(sched, clock("Mon", "00", "10")), "next day, even though < 59 min later");
});

Deno.test("homeInstant: 18:00 on the home clock, either side of the clocks changing", () => {
  const summer = homeInstant("Europe/London", "2026-09-24", 18);
  assert(summer.toISOString() === "2026-09-24T17:00:00.000Z", summer.toISOString());
  const winter = homeInstant("Europe/London", "2026-12-10", 18);
  assert(winter.toISOString() === "2026-12-10T18:00:00.000Z", winter.toISOString());
  const changeDay = homeInstant("Europe/London", "2026-10-25", 18);
  assert(changeDay.toISOString() === "2026-10-25T18:00:00.000Z", changeDay.toISOString());
  const tokyo = homeInstant("Asia/Tokyo", "2026-09-24", 9);
  assert(tokyo.toISOString() === "2026-09-24T00:00:00.000Z", tokyo.toISOString());
  const ny = homeInstant("America/New_York", "2026-03-08", 18);
  assert(ny.toISOString() === "2026-03-08T22:00:00.000Z", ny.toISOString());
});
