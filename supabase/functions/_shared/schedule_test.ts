import { isDue, localClock, localDate, weekMonday } from "./schedule.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

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

Deno.test("isDue: a schedule near midnight does not spill into the next day", () => {
  const sched = { day_of_week: 7, hour: 23, minute: 30 };
  const clock = (weekday: string, hour: string, minute: string) => ({ weekday, hour, minute, year: "2026", month: "09", day: "13" });
  assert(isDue(sched, clock("Sun", "23", "45")), "same day, inside window");
  assert(!isDue(sched, clock("Mon", "00", "10")), "next day, even though < 59 min later");
});
