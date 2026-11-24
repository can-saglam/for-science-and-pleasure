import { assertEquals } from "jsr:@std/assert";
import { problems, type RunRow } from "./runs.ts";

const now = new Date("2026-11-24T08:00:00Z");
const at = (minutesAgo: number) => new Date(now.getTime() - minutesAgo * 60_000).toISOString();
const run = (job: string, minutesAgo: number, ok = true, error?: string): RunRow => ({
  job, ok, finished_at: at(minutesAgo), detail: error ? { error } : {},
});
const healthy = [
  run("reminders-tick", 10), run("warm-cities", 5), run("verify-entitlements", 40), run("purge-nightly", 260),
];

Deno.test("all jobs inside their windows is quiet", () => {
  assertEquals(problems(healthy, now), []);
});

Deno.test("a job that stopped is named with how long ago", () => {
  const runs = [...healthy.filter((r) => r.job !== "reminders-tick"), run("reminders-tick", 200)];
  assertEquals(problems(runs, now), ["reminders-tick last finished 3 h ago"]);
});

Deno.test("send-reminders may be quiet, but its failures count", () => {
  assertEquals(problems([...healthy, run("send-reminders", 900)], now), []);
  assertEquals(problems([...healthy, run("send-reminders", 30, false, "1 group step failed")], now), [
    "send-reminders failed once: 1 group step failed",
  ]);
});

Deno.test("a job with no run at all says so", () => {
  assertEquals(problems(healthy.filter((r) => r.job !== "purge-nightly"), now), [
    "purge-nightly hasn't finished a run in a day",
  ]);
});

Deno.test("failures are counted, with the latest error", () => {
  const runs = [
    ...healthy,
    run("verify-entitlements", 100, false, "old"),
    run("verify-entitlements", 70, false, "apple said 401"),
  ];
  assertEquals(problems(runs, now), ["verify-entitlements failed 2 times: apple said 401"]);
});

Deno.test("only failing runs since the last good one still count as stopped", () => {
  const runs = [...healthy.filter((r) => r.job !== "warm-cities"), run("warm-cities", 5, false), run("warm-cities", 90)];
  assertEquals(problems(runs, now), ["warm-cities last finished 1 h ago"]);
});
