// What the warm-up (warm-cities) does next, decided from demand: cities
// people asked about lately are kept fresh before they go stale, the
// hand-picked seeds bridge the launch, and cities nobody asks about stop
// costing anything.
import { type SuggestionKind, isDue, leaseFree, servePool } from "./suggestions.ts";

/// Asked about within this many days: refreshed when due, as an ask would.
export const ACTIVE_DAYS = 14;
/// How far back demand counts at all; city_asks keeps a little longer.
export const DEMAND_DAYS = 90;
/// After going live, seeds keep their top-ups this long without demand.
export const SEED_GRACE_DAYS = 90;
/// A thin pool nobody's asking about waits this long for a top-up.
export const TOP_UP_DAYS = 21;
/// A search that found nothing or failed waits this long before the
/// warm-up retries it, so one stubborn city can't spend every quarter hour.
export const RETRY_DAYS = 7;
/// Spend on warm-up searches each calendar month; asks are never capped.
export const MONTHLY_BUDGET_USD = 30;

const DAY = 86_400_000;

export interface Candidate {
  key: string;
  locality: string;
  country: string;
  seed: boolean;
  /// Different people who asked within DEMAND_DAYS.
  askers: number;
  lastAsked: string | null;
}

export interface Pool {
  payload: unknown;
  fetched_at: string | null;
  refreshing_since: string | null;
}

export interface Context {
  now: number;
  today: string;
  /// First App Store ask; null before launch.
  liveSince: string | null;
  busy: boolean;
  /// A search of this kind that didn't keep anything within `days`.
  failed: (kind: SuggestionKind, days: number) => boolean;
}

export const active = (c: Candidate, today: string) =>
  !!c.lastAsked && Date.parse(today) - Date.parse(c.lastAsked) <= ACTIVE_DAYS * DAY;

/// Worth a top-up with nobody asking lately: a seed until it's had its
/// chance after launch, or a city more than one person has asked about
/// (one person alone could be anything they typed).
export function kept(c: Candidate, ctx: Pick<Context, "now" | "liveSince">): boolean {
  if (c.askers >= 2) return true;
  if (!c.seed) return false;
  if (!ctx.liveSince || c.askers > 0) return true;
  return ctx.now < Date.parse(ctx.liveSince) + SEED_GRACE_DAYS * DAY;
}

export function wanted(
  c: Candidate,
  pools: Partial<Record<SuggestionKind, Pool>>,
  ctx: Context,
): SuggestionKind[] {
  const kinds: SuggestionKind[] = [];
  for (const kind of ["event", "place"] as const) {
    const pool = pools[kind];
    if (!leaseFree(pool?.refreshing_since ?? null, new Date(ctx.now))) continue;
    if (!pool?.fetched_at) {
      if ((c.seed || c.askers > 0) && !ctx.failed(kind, RETRY_DAYS)) kinds.push(kind);
      continue;
    }
    const live = servePool(pool.payload, kind, ctx.today).length;
    if (active(c, ctx.today)) {
      if (isDue(pool.fetched_at, kind, live, new Date(ctx.now), ctx.busy) && !ctx.failed(kind, 1)) kinds.push(kind);
    } else if (
      kind === "event" && live < 3 &&
      ctx.now - Date.parse(pool.fetched_at) >= TOP_UP_DAYS * DAY &&
      kept(c, ctx) && !ctx.failed(kind, RETRY_DAYS)
    ) {
      kinds.push(kind);
    }
  }
  return kinds;
}

/// Seeds in their listed order merged with demand, the cities people are
/// using now first, most-asked first.
export function candidates(
  seeds: { key: string; locality: string; country: string }[],
  demand: { key: string; locality: string; country: string; askers: number; last_day: string }[],
  today: string,
): Candidate[] {
  const byKey = new Map<string, Candidate>();
  for (const s of seeds) byKey.set(s.key, { ...s, seed: true, askers: 0, lastAsked: null });
  for (const d of demand) {
    const seed = byKey.get(d.key);
    byKey.set(d.key, {
      key: d.key,
      locality: seed?.locality ?? d.locality,
      country: seed?.country ?? d.country,
      seed: !!seed,
      askers: d.askers,
      lastAsked: d.last_day,
    });
  }
  const all = [...byKey.values()];
  const rank = (c: Candidate) => (active(c, today) ? 0 : 1);
  return all
    .map((c, i) => ({ c, i }))
    .sort((a, b) => rank(a.c) - rank(b.c) || (rank(a.c) === 0 ? b.c.askers - a.c.askers : 0) || a.i - b.i)
    .map(({ c }) => c);
}

/// Rough dollars for one run, at Sonnet-class list prices plus $10 per
/// thousand web searches. Only for the budget, not billing.
export function runCost(r: { input_tokens: number | null; output_tokens: number | null; searches: number | null }) {
  return ((r.input_tokens ?? 0) * 3 + (r.output_tokens ?? 0) * 15) / 1e6 + (r.searches ?? 0) * 0.01;
}
