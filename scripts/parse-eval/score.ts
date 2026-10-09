// What a test case expects, what a run produced, and how the two compare.

import type { EarlyCard, Page } from "../../supabase/functions/_shared/extract.ts";

export interface Case {
  id: string;
  /** page: a link whose page was read; walled: a link that couldn't be,
   * so the parser searches; maps, social: those links; typed: words only;
   * search: words that should be refused. */
  group: "page" | "walled" | "maps" | "social" | "typed" | "search";
  input: string;
  /** The page as read when the case was collected; null when it couldn't
   * be. Absent for anything that isn't a plain web link. */
  page?: Page | null;
  expect: {
    vague: boolean;
    kind?: "event" | "place";
    title?: string;
    venue?: string | null;
    category?: string | null;
    starts_on?: string | null;
    ends_on?: string | null;
    /** The site the save's link or official website should be on. */
    host?: string | null;
    photo?: boolean;
  };
}

export interface Outcome {
  id: string;
  group: Case["group"];
  input: string;
  ms: number;
  early_ms: number | null;
  /** The model's fields, as they reached the phone. */
  early: EarlyCard | null;
  card: {
    title: string;
    kind: string;
    venue: string | null;
    category: string | null;
    starts_on: string | null;
    ends_on: string | null;
    url: string | null;
    website: string | null;
    image_url: string | null;
  } | null;
  meta?: Record<string, unknown>;
  error: { name: string; message: string; status?: number } | null;
  checks: Record<string, boolean>;
}

function norm(s: string): string {
  return s
    .normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\b(the|a|an|at|of)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/// Same name, allowing for "The", a trailing venue, or a subtitle.
export function similar(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return false;
  const x = norm(a), y = norm(b);
  if (!x || !y) return false;
  if (x.includes(y) || y.includes(x)) return true;
  const xs = new Set(x.split(" ")), ys = new Set(y.split(" "));
  const shared = [...xs].filter((w) => ys.has(w)).length;
  return shared / Math.min(xs.size, ys.size) >= 0.6;
}

function onHost(link: string | null | undefined, host: string): boolean {
  if (!link) return false;
  try {
    const h = new URL(link).hostname.replace(/^www\./, "");
    return h === host || h.endsWith(`.${host}`) || host.endsWith(`.${h}`);
  } catch {
    return false;
  }
}

export function score(c: Case, o: Omit<Outcome, "checks">): Record<string, boolean> {
  const refused = o.error?.name === "VagueInputError";
  const checks: Record<string, boolean> = { refused: refused === c.expect.vague };
  if (c.expect.vague) return checks;
  // The model's own answer, even when a later step threw it away.
  const got = o.card ?? o.early;
  const e = c.expect;
  if (e.kind) checks.kind = got?.kind === e.kind;
  if (e.title) checks.title = similar(got?.title, e.title);
  if (e.venue) checks.venue = similar(got?.venue, e.venue) || similar(got?.title, e.venue);
  if (e.category) checks.category = got?.category === e.category;
  if (e.starts_on) checks.starts_on = got?.starts_on === e.starts_on;
  if (e.ends_on) checks.ends_on = got?.ends_on === e.ends_on;
  if (e.host) checks.host = onHost(o.card?.url, e.host) || onHost(o.card?.website, e.host);
  if (e.photo) checks.photo = Boolean(o.card?.image_url);
  return checks;
}

export interface Summary {
  label: string;
  at: string;
  cases: number;
  /** Share of all checks passed. */
  score: number;
  /** Share of cases with every check passed. */
  clean: number;
  by_check: Record<string, { pass: number; of: number }>;
  by_group: Record<string, { score: number; cases: number }>;
  failures: number;
  ms_p50: number;
  ms_p90: number;
  early_p50: number | null;
  /** The quick search check on typed cases: right calls out of all. */
  gate?: { pass: number; of: number };
  /** Totals across the run, where the parser reported them. */
  usage?: { input_tokens: number; output_tokens: number; searches: number };
}

function pct(list: number[], p: number): number {
  if (!list.length) return 0;
  const sorted = [...list].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
}

export function summarise(label: string, outcomes: Outcome[]): Summary {
  const by_check: Summary["by_check"] = {};
  const groups: Record<string, { pass: number; of: number; cases: number }> = {};
  let pass = 0, of = 0, clean = 0;
  for (const o of outcomes) {
    const entries = Object.entries(o.checks);
    const g = groups[o.group] ??= { pass: 0, of: 0, cases: 0 };
    g.cases++;
    for (const [name, ok] of entries) {
      const c = by_check[name] ??= { pass: 0, of: 0 };
      c.of++;
      g.of++;
      of++;
      if (ok) c.pass++, g.pass++, pass++;
    }
    if (entries.every(([, ok]) => ok)) clean++;
  }
  const early = outcomes.map((o) => o.early_ms).filter((ms): ms is number => ms !== null);
  const sum = (key: string) => outcomes.reduce((n, o) => n + (Number(o.meta?.[key]) || 0), 0);
  return {
    usage: outcomes.some((o) => o.meta?.model)
      ? { input_tokens: sum("input_tokens"), output_tokens: sum("output_tokens"), searches: sum("searches") }
      : undefined,
    label,
    at: new Date().toISOString(),
    cases: outcomes.length,
    score: of ? pass / of : 0,
    clean: outcomes.length ? clean / outcomes.length : 0,
    by_check,
    by_group: Object.fromEntries(
      Object.entries(groups).map(([name, g]) => [name, { score: g.of ? g.pass / g.of : 0, cases: g.cases }]),
    ),
    failures: outcomes.filter((o) => o.error && o.error.name !== "VagueInputError").length,
    ms_p50: pct(outcomes.map((o) => o.ms), 0.5),
    ms_p90: pct(outcomes.map((o) => o.ms), 0.9),
    early_p50: early.length ? pct(early, 0.5) : null,
  };
}
