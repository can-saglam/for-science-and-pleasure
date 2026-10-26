import { assertEquals } from "jsr:@std/assert";
import { type Candidate, type Context, type Pool, candidates, kept, runCost, wanted } from "./warm_plan.ts";

const DAY = 86_400_000;
const today = "2026-10-22";
const now = Date.parse(`${today}T12:00:00Z`);
const ago = (days: number) => new Date(now - days * DAY).toISOString();
const ctx = (over: Partial<Context> = {}): Context => ({
  now, today, liveSince: null, busy: false, failed: () => false, ...over,
});
const city = (over: Partial<Candidate> = {}): Candidate => ({
  key: "x|y", locality: "X", country: "Y", seed: false, askers: 0, lastAsked: null, ...over,
});
const event = (ends: string) => ({
  kind: "event", title: `E ${ends}`, venue: null, starts_on: null, ends_on: ends, summary: "", url: "https://example.com",
});
const pool = (fetched: number, items: unknown[] = []): Pool => ({
  payload: { items }, fetched_at: ago(fetched), refreshing_since: null,
});

Deno.test("a seed with nothing yet gets both kinds", () => {
  assertEquals(wanted(city({ seed: true }), {}, ctx()), ["event", "place"]);
});

Deno.test("a city people use now refreshes when due, not before", () => {
  const c = city({ askers: 3, lastAsked: "2026-10-20" });
  const plenty = Array.from({ length: 5 }, () => event("2026-11-30"));
  const places = plenty.map((e) => ({ ...e, kind: "place", ends_on: null }));
  assertEquals(wanted(c, { event: pool(2, plenty), place: pool(5, places) }, ctx()), []);
  assertEquals(wanted(c, { event: pool(8, plenty), place: pool(31, places) }, ctx()), ["event", "place"]);
  assertEquals(wanted(c, { event: pool(4, plenty), place: pool(5, places) }, ctx({ busy: true })), ["event"]);
});

Deno.test("a quiet seed tops up its thin events until it's had its chance", () => {
  const thin = { event: pool(22), place: pool(40) };
  assertEquals(wanted(city({ seed: true }), thin, ctx()), ["event"]);
  assertEquals(wanted(city({ seed: true }), thin, ctx({ liveSince: "2026-09-01" })), ["event"]);
  assertEquals(wanted(city({ seed: true }), thin, ctx({ liveSince: "2026-06-01" })), []);
  assertEquals(wanted(city({ seed: true, askers: 1, lastAsked: "2026-08-01" }), thin, ctx({ liveSince: "2026-06-01" })), ["event"]);
  assertEquals(wanted(city({ seed: true }), { event: pool(10), place: pool(40) }, ctx()), []);
});

Deno.test("one person alone doesn't keep a city topped up; two do", () => {
  const live = { liveSince: "2026-01-01" };
  assertEquals(kept(city({ askers: 1 }), { now, ...live }), false);
  assertEquals(kept(city({ askers: 2 }), { now, ...live }), true);
});

Deno.test("a failed search waits, and a running one isn't doubled", () => {
  assertEquals(wanted(city({ seed: true }), {}, ctx({ failed: (k) => k === "event" })), ["place"]);
  const running = { payload: { items: [] }, fetched_at: null, refreshing_since: ago(0.001) };
  assertEquals(wanted(city({ seed: true }), { event: running }, ctx()), ["place"]);
});

Deno.test("cities in use come first, most asked first, then seeds in order", () => {
  const list = candidates(
    [{ key: "a", locality: "A", country: "Z" }, { key: "b", locality: "B", country: "Z" }],
    [
      { key: "c", locality: "C", country: "Z", askers: 2, last_day: "2026-10-21" },
      { key: "b", locality: "b-ish", country: "Z", askers: 5, last_day: "2026-10-21" },
      { key: "d", locality: "D", country: "Z", askers: 9, last_day: "2026-06-01" },
    ],
    today,
  );
  assertEquals(list.map((c) => c.key), ["b", "c", "a", "d"]);
  assertEquals(list[0].locality, "B");
  assertEquals(list[0].seed, true);
});

Deno.test("run cost roughly matches an event search", () => {
  const cost = runCost({ input_tokens: 172_000, output_tokens: 28_000, searches: 12 });
  assertEquals(Math.round(cost * 100), 106);
});
