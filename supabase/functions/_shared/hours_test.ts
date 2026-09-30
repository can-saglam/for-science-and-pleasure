import {
  type Hours,
  hoursApply,
  hoursLine,
  hoursForPlanning,
  hoursShown,
  type Period,
  samePlace,
  venueToday,
  weekFrom,
} from "./hours.ts";
import { isVenue } from "./places.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}
const eq = (a: unknown, b: unknown, msg: string) =>
  assert(JSON.stringify(a) === JSON.stringify(b), `${msg}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);

const event = (category: string, starts_on: string | null, ends_on: string | null) =>
  ({ kind: "event", category, starts_on, ends_on });

Deno.test("hoursApply: places but not venues; exhibitions and markets that run for days", () => {
  assert(hoursApply({ kind: "place", category: "restaurant", starts_on: null, ends_on: null }), "restaurant");
  assert(hoursApply({ kind: "place", category: null, starts_on: null, ends_on: null }), "uncategorised place");
  assert(!hoursApply({ kind: "place", category: "venue", starts_on: null, ends_on: null }), "concert hall");
  assert(hoursApply(event("exhibition", "2026-09-01", "2026-12-01")), "long show");
  assert(hoursApply(event("exhibition", "2026-09-01", "2026-09-04")), "three days on");
  assert(!hoursApply(event("exhibition", "2026-09-01", "2026-09-03")), "two days on");
  assert(hoursApply(event("exhibition", null, "2026-12-01")), "until a date");
  assert(hoursApply(event("market", null, null)), "undated market");
  assert(!hoursApply(event("theatre", "2026-09-01", "2026-12-01")), "a run of shows keeps show times");
  assert(!hoursApply(event("gig", "2026-09-01", "2026-09-01")), "gig");
});

Deno.test("hoursShown: an event's only while it's on", () => {
  const show = event("exhibition", "2026-10-02", "2027-01-10");
  assert(!hoursShown(show, "2026-09-28"), "not open yet");
  assert(hoursShown(show, "2026-10-02"), "opening day");
  assert(hoursShown(show, "2027-01-10"), "last day");
  assert(!hoursShown(show, "2027-01-11"), "closed");
  assert(hoursShown(event("exhibition", null, null), "2026-09-28"), "undated");
  assert(hoursShown({ kind: "place", category: "cafe", starts_on: null, ends_on: null }, "2026-09-28"), "place");
});

Deno.test("hoursForPlanning: before an event opens too, never once it's over", () => {
  const show = event("exhibition", "2026-10-02", "2027-01-10");
  assert(hoursForPlanning(show, "2026-09-28"), "not open yet");
  assert(hoursForPlanning(show, "2027-01-10"), "last day");
  assert(!hoursForPlanning(show, "2027-01-11"), "over");
  assert(!hoursForPlanning(event("gig", "2026-10-02", "2026-10-02"), "2026-09-28"), "a night out has no hours");
  assert(hoursForPlanning({ kind: "place", category: "cafe", starts_on: null, ends_on: null }, "2026-09-28"), "place");
});

// Hayward's regular week: closed Monday, 10–18, Saturday until 20.
const hayward: Period[] = [
  ...[2, 3, 4, 5, 0].map((day) => ({ open: { day, hour: 10, minute: 0 }, close: { day, hour: 18, minute: 0 } })),
  { open: { day: 6, hour: 10, minute: 0 }, close: { day: 6, hour: 20, minute: 0 } },
];

Deno.test("weekFrom: regular hours by weekday, today first", () => {
  // 2026-09-28 is a Monday.
  const week = weekFrom(hayward, "2026-09-28");
  eq(week.map((d) => d.date), [
    "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04",
  ], "dates");
  eq(week[0].ranges, [], "closed Monday");
  eq(week[1].ranges, [{ open: "10:00", close: "18:00" }], "Tuesday");
  eq(week[5].ranges, [{ open: "10:00", close: "20:00" }], "Saturday late");
});

Deno.test("weekFrom: current hours follow their dates, split days sort, overnight closes keep their day", () => {
  const d = (day: number) => ({ year: 2026, month: 10, day });
  const current: Period[] = [
    { open: { day: 3, hour: 18, minute: 0, date: d(1) }, close: { day: 4, hour: 2, minute: 0, date: d(2) } },
    { open: { day: 3, hour: 12, minute: 0, date: d(1) }, close: { day: 3, hour: 15, minute: 0, date: d(1) } },
  ];
  const week = weekFrom(current, "2026-09-30");
  eq(week[0].ranges, [], "nothing listed for the 30th");
  eq(week[1].ranges, [{ open: "12:00", close: "15:00" }, { open: "18:00", close: "02:00" }], "1 October");
  eq(week[2].ranges, [], "the 2am close belongs to the day before");
});

Deno.test("weekFrom: a lone Sunday-midnight opening is round the clock", () => {
  const week = weekFrom([{ open: { day: 0, hour: 0, minute: 0 } }], "2026-09-28");
  assert(week.every((d) => JSON.stringify(d.ranges) === JSON.stringify([{ open: "00:00", close: "24:00" }])), "24/7");
});

const hoursOf = (ranges: { open: string; close: string }[], status: Hours["status"] = "open"): Hours =>
  ({ status, days: [{ date: "2026-09-29", ranges }], offset: 60 });
const at = (hm: string) => Number(hm.slice(0, 2)) * 60 + Number(hm.slice(3));

Deno.test("hoursLine reads today at the moment the activity starts", () => {
  const day = hoursOf([{ open: "10:00", close: "18:00" }]);
  eq(hoursLine(day, at("09:00")), "Open 10:00–18:00", "before opening");
  eq(hoursLine(day, at("10:00")), "Open until 18:00", "at opening");
  eq(hoursLine(day, at("17:59")), "Open until 18:00", "just before close");
  eq(hoursLine(day, at("18:00")), "Closed for the day", "after close");
  const split = hoursOf([{ open: "12:00", close: "15:00" }, { open: "18:00", close: "23:00" }]);
  eq(hoursLine(split, at("10:00")), "Opens 12:00", "split, before");
  eq(hoursLine(split, at("16:00")), "Reopens 18:00", "between");
  eq(hoursLine(split, at("19:00")), "Open until 23:00", "second sitting");
  const late = hoursOf([{ open: "17:00", close: "02:00" }]);
  eq(hoursLine(late, at("22:00")), "Open until 02:00", "past midnight");
  eq(hoursLine(hoursOf([{ open: "12:00", close: "00:00" }]), at("20:00")), "Open until midnight", "midnight");
  eq(hoursLine(hoursOf([]), at("10:00")), "Closed today", "closed");
  eq(hoursLine(hoursOf([{ open: "00:00", close: "24:00" }]), at("10:00")), "Open 24 hours", "24h");
  eq(hoursLine({ status: "closed_temporarily", days: [], offset: 0 }, at("10:00")), "Temporarily closed", "temp");
});

Deno.test("venueToday uses the venue's offset", () => {
  const now = new Date("2026-09-28T23:30:00Z");
  eq(venueToday(now, 60), "2026-09-29", "London in summer");
  eq(venueToday(now, -240), "2026-09-28", "New York");
});

Deno.test("samePlace: the venue's name, a place's title, or the postcode", () => {
  eq(samePlace({ title: "Kin", venue: "Phillida Reid" }, { name: "Phillida Reid", address: null }), true, "venue");
  eq(samePlace({ title: "St. JOHN Smithfield", venue: "St. JOHN" }, { name: "St. John", address: null }), true, "chain");
  eq(
    samePlace({ title: "Lawrence Abu Hamdan", venue: "Barbican Centre" }, { name: "Barbican Art Gallery", address: null }),
    true,
    "gallery inside",
  );
  eq(
    samePlace(
      { title: "Show", venue: "V&A South Kensington", address: "Cromwell Road, London SW7 2RL" },
      { name: "Victoria and Albert Museum", address: "Cromwell Rd, London SW7 2RL, UK" },
    ),
    true,
    "postcode",
  );
  eq(samePlace({ title: "Show", venue: "Tate Britain" }, { name: "Tate Modern", address: null }), false, "a moved venue");
});

Deno.test("isVenue turns away cities and streets", () => {
  assert(!isVenue({ types: ["locality", "political"] }), "London");
  assert(!isVenue({ types: ["route"] }), "a street");
  assert(isVenue({ types: ["art_gallery", "point_of_interest", "establishment"] }), "gallery");
});
