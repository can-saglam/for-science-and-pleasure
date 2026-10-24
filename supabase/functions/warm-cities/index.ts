// warm-cities: keeps suggestions ready where people want them, so a list is
// there at once instead of after a three-minute search. pg_cron calls it
// every 15 minutes (0050) with the shared cron secret; each call starts at
// most one city, so work spreads over the day rather than landing at once.
//
// What it does follows demand (warm_plan.ts, city_asks in 0051):
// - Cities people asked about in the last two weeks are refreshed when
//   due, busiest first, so the next person finds a fresh list rather than
//   triggering the search themselves.
// - SEEDS get a first pool before anyone arrives (about $1.45 a city) and
//   a top-up once they've thinned out. That lasts until 90 days after the
//   first App Store install; then a seed nobody asks about stops costing.
// - A city more than one person asked about gets the same top-ups.
// - Warm-up spend stops at MONTHLY_BUDGET_USD a month; asks never wait on it.
import { sameSecret } from "../_shared/auth.ts";
import { admin } from "../_shared/groups.ts";
import { cityJobs } from "../_shared/suggestion_jobs.ts";
import { starterKey } from "../_shared/starters.ts";
import { BUSY_CITY_PEOPLE, type SuggestionKind, busyMatters } from "../_shared/suggestions.ts";
import {
  DEMAND_DAYS,
  MONTHLY_BUDGET_USD,
  RETRY_DAYS,
  type Pool,
  active,
  candidates,
  runCost,
  wanted,
} from "../_shared/warm_plan.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

/// Where the first people are joining from: the UK and Türkiye, the
/// European cities they most often go out in, then a few big ones further
/// afield. Spelled the way the phone names them, so the keys match what
/// the app asks for. Once live, demand adds cities by itself.
const SEEDS: [locality: string, country: string][] = [
  ["London", "United Kingdom"],
  ["Manchester", "United Kingdom"],
  ["Edinburgh", "United Kingdom"],
  ["Bristol", "United Kingdom"],
  ["Glasgow", "United Kingdom"],
  ["Istanbul", "Türkiye"],
  ["İzmir", "Türkiye"],
  ["Ankara", "Türkiye"],
  ["Paris", "France"],
  ["Berlin", "Germany"],
  ["Amsterdam", "Netherlands"],
  ["Lisbon", "Portugal"],
  ["Barcelona", "Spain"],
  ["Dublin", "Ireland"],
  ["New York", "United States"],
  ["Singapore", "Singapore"],
  ["Seoul", "South Korea"],
  ["Mexico City", "Mexico"],
  ["Melbourne", "Australia"],
];

/// city_asks rows older than this go; a little past DEMAND_DAYS.
const KEEP_ASKS_DAYS = 120;
const DAY = 86_400_000;

interface Row extends Pool {
  key: string;
  kind: SuggestionKind;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const daysBefore = (now: number, days: number) => new Date(now - days * DAY).toISOString().slice(0, 10);

Deno.serve(async (req) => {
  const expected = Deno.env.get("REMINDERS_CRON_SECRET");
  if (!expected || !sameSecret(req.headers.get("x-cron-secret"), expected)) return json({ error: "forbidden" }, 403);

  const db = admin();
  const now = Date.now();
  const today = new Date(now).toISOString().slice(0, 10);
  const monthStart = `${today.slice(0, 7)}-01T00:00:00Z`;

  // A read that fails would look like a city with nothing in it, and
  // "warm everything" is the expensive mistake; better to skip a turn.
  const failure = (...results: { error: { message: string } | null }[]) =>
    results.find((r) => r.error)?.error?.message;

  const [spentResult, demandResult, firstResult] = await Promise.all([
    db.from("suggestion_runs").select("input_tokens, output_tokens, searches").eq("warm", true).gte("at", monthStart),
    db.rpc("city_demand", { p_since: daysBefore(now, DEMAND_DAYS) }),
    db.from("city_asks").select("day").eq("store", true).order("day").limit(1).maybeSingle(),
    db.from("city_asks").delete().lt("day", daysBefore(now, KEEP_ASKS_DAYS)),
  ]);
  const early = failure(spentResult, demandResult, firstResult);
  if (early) return json({ error: early }, 500);
  const { data: spentData } = spentResult;
  const { data: demandData } = demandResult;
  const { data: firstStore } = firstResult;

  const spent = (spentData ?? []).reduce((sum, r) => sum + runCost(r), 0);
  if (spent >= MONTHLY_BUDGET_USD) return json({ warming: null, paused: "budget", spent: Math.round(spent) });

  const seeds = SEEDS.map(([locality, country]) => ({ key: starterKey(locality, country), locality, country }));
  const list = candidates(seeds, demandData ?? [], today);
  const keys = list.map((c) => c.key);

  const [rowResult, runResult] = await Promise.all([
    db.from("city_suggestions").select("key, kind, payload, fetched_at, refreshing_since").in("key", keys),
    db.from("suggestion_runs").select("key, kind, at").neq("outcome", "kept")
      .gte("at", new Date(now - RETRY_DAYS * DAY).toISOString()),
  ]);
  const late = failure(rowResult, runResult);
  if (late) return json({ error: late }, 500);
  const rows = (rowResult.data ?? []) as Row[];
  const runs = (runResult.data ?? []) as { key: string; kind: SuggestionKind; at: string }[];
  const liveSince = (firstStore as { day: string } | null)?.day ?? null;

  for (const c of list) {
    const pools: Partial<Record<SuggestionKind, Pool>> = {};
    for (const r of rows) if (r.key === c.key) pools[r.kind] = r;

    let busy = false;
    if (active(c, today) && busyMatters(pools.event?.fetched_at ?? null, "event", new Date(now))) {
      const { data: people } = await db.rpc("city_people", { p_key: c.key });
      busy = typeof people === "number" && people >= BUSY_CITY_PEOPLE;
    }
    const failed = (kind: SuggestionKind, days: number) =>
      runs.some((r) => r.key === c.key && r.kind === kind && now - Date.parse(r.at) < days * DAY);

    const kinds = wanted(c, pools, { now, today, liveSince, busy, failed });
    if (kinds.length === 0) continue;

    const { refresh } = cityJobs(db, { key: c.key, locality: c.locality, country: c.country, today, warm: true }, () => busy);
    const work = Promise.all(kinds.map((kind) => refresh(kind)));
    if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(work);
    else await work;
    return json({ warming: c.key, kinds, askers: c.askers, spent: Math.round(spent) });
  }
  return json({ warming: null, spent: Math.round(spent) });
});
