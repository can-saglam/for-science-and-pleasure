// Runs the test set through the parser and scores it, or compares two runs.
//
//   deno run -A scripts/parse-eval/run.ts --label baseline
//   deno run -A scripts/parse-eval/run.ts --label sonnet --only page,walled
//   deno run -A scripts/parse-eval/run.ts --compare baseline sonnet
//   deno run -A scripts/parse-eval/run.ts --label haiku --gate
//
// PARSE_READ_MODEL, PARSE_SEARCH_MODEL and PARSE_GATE_MODEL in the
// environment try another model on that route.
//
// Each run calls Claude once per case (searching for most non-page cases),
// plus the quick search check once per typed case. Results go to
// scripts/parse-eval/data/results/<label>.json. The model doesn't answer
// identically twice, so a gap of a check or two between runs is noise;
// --repeat runs every case more than once to see past it.
//
// Without GOOGLE_MAPS_API_KEY in the environment Google's place lookups
// are skipped, so the photo check reads lower than in production.

import { type Outcome, type Summary, score, summarise, type Case } from "./score.ts";

const DATA = "scripts/parse-eval/data";
const args = Deno.args;
const flag = (name: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
};

async function load(label: string): Promise<{ summary: Summary; outcomes: Outcome[] }> {
  return JSON.parse(await Deno.readTextFile(`${DATA}/results/${label}.json`));
}

function line(s: Summary): string {
  const p = (n: number) => `${(n * 100).toFixed(1)}%`;
  return `${s.label.padEnd(14)} score ${p(s.score)}  clean ${p(s.clean)}  failures ${s.failures}  ` +
    `p50 ${(s.ms_p50 / 1000).toFixed(1)}s  p90 ${(s.ms_p90 / 1000).toFixed(1)}s  ` +
    `first fields p50 ${s.early_p50 === null ? "—" : `${(s.early_p50 / 1000).toFixed(1)}s`}` +
    (s.gate ? `  search check ${s.gate.pass}/${s.gate.of}` : "") +
    (s.usage
      ? `  tokens ${Math.round(s.usage.input_tokens / 1000)}k in / ${Math.round(s.usage.output_tokens / 1000)}k out, ${s.usage.searches} searches`
      : "");
}

function table(summaries: Summary[]) {
  const checks = [...new Set(summaries.flatMap((s) => Object.keys(s.by_check)))];
  const groups = [...new Set(summaries.flatMap((s) => Object.keys(s.by_group)))];
  const head = "".padEnd(12) + summaries.map((s) => s.label.padStart(14)).join("");
  console.log(`\n${head}`);
  for (const c of checks) {
    console.log(c.padEnd(12) + summaries.map((s) => {
      const v = s.by_check[c];
      return (v ? `${v.pass}/${v.of}` : "—").padStart(14);
    }).join(""));
  }
  console.log("");
  for (const g of groups) {
    console.log(g.padEnd(12) + summaries.map((s) => {
      const v = s.by_group[g];
      return (v ? `${(v.score * 100).toFixed(0)}% of ${v.cases}` : "—").padStart(14);
    }).join(""));
  }
}

const compare = args.indexOf("--compare");
if (compare >= 0) {
  const [a, b] = await Promise.all([load(args[compare + 1]), load(args[compare + 2])]);
  console.log(line(a.summary));
  console.log(line(b.summary));
  table([a.summary, b.summary]);
  const before = new Map(a.outcomes.map((o) => [`${o.id}`, o]));
  const moved: string[] = [];
  for (const o of b.outcomes) {
    const was = before.get(o.id);
    if (!was) continue;
    for (const [name, ok] of Object.entries(o.checks)) {
      if (name in was.checks && was.checks[name] !== ok) {
        moved.push(`${ok ? "+" : "-"} ${name.padEnd(10)} ${o.input.slice(0, 70)}${
          ok ? "" : `  (${describe(o, name)})`
        }`);
      }
    }
  }
  console.log(`\nChecks that changed (${moved.length}):`);
  for (const m of moved.sort()) console.log(`  ${m}`);
  Deno.exit(0);
}

function describe(o: Outcome, check: string): string {
  if (o.error) return `${o.error.name}: ${o.error.message.slice(0, 80)}`;
  const got = (o.card ?? o.early) as Record<string, unknown> | null;
  if (!got) return "no answer";
  if (check === "host") return `${o.card?.url ?? "—"} / ${o.card?.website ?? "—"}`;
  if (check === "photo") return "no photo";
  if (check === "refused") return "not refused";
  return String(got[check] ?? "null");
}

const label = flag("label");
if (!label) {
  console.error("Pass --label <name> to run, or --compare <a> <b>.");
  Deno.exit(1);
}
const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const anthropicKey = env.match(/^ANTHROPIC_API_KEY=(.*)$/m)?.[1]?.trim();
if (!anthropicKey) {
  console.error("Missing ANTHROPIC_API_KEY in .supabase.env");
  Deno.exit(1);
}
Deno.env.set("ANTHROPIC_API_KEY", anthropicKey);
const { extractCard, looksLikeSearch } = await import("../../supabase/functions/_shared/extract.ts");

const typed = JSON.parse(await Deno.readTextFile("scripts/parse-eval/typed.json")) as Case[];

// --gate: only the quick search check, on the typed cases plus gate.json.
if (args.includes("--gate")) {
  const pairs = JSON.parse(await Deno.readTextFile("scripts/parse-eval/gate.json")) as [string, boolean][];
  const all = [...typed.map((c) => [c.input, c.expect.vague] as [string, boolean]), ...pairs];
  const wrong: string[] = [];
  const times: number[] = [];
  await Promise.all(all.map(async ([input, search]) => {
    const started = Date.now();
    if (await looksLikeSearch(input) !== search) wrong.push(`${input} (${search ? "a search" : "a name"})`);
    times.push(Date.now() - started);
  }));
  times.sort((a, b) => a - b);
  console.log(
    `${label.padEnd(14)} ${all.length - wrong.length}/${all.length} right  p50 ${times[times.length >> 1]}ms` +
      (wrong.length ? `  wrong: ${wrong.join("; ")}` : ""),
  );
  Deno.exit(0);
}

const library = JSON.parse(await Deno.readTextFile(`${DATA}/cases.json`)) as { cases: Case[] };
const only = flag("only")?.split(",");
const repeat = Number(flag("repeat") ?? 1);
const queue = [...library.cases, ...typed]
  .filter((c) => !only || only.includes(c.group))
  .flatMap((c) => Array.from({ length: repeat }, () => c));

// The parser logs its timing line per call; keep the runner's output to
// the progress lines.
const log = console.log;
console.log = () => {};

const outcomes: Outcome[] = [];
const gate = { pass: 0, of: 0 };
let done = 0;
async function work() {
  for (let c = queue.shift(); c; c = queue.shift()) {
    const started = Date.now();
    let early_ms: number | null = null;
    let early: Outcome["early"] = null;
    let card: Outcome["card"] = null;
    // The parse function's own budget, so a run that would time out there
    // fails here too.
    const meta: Record<string, unknown> = { deadline: started + 110_000 };
    let error: Outcome["error"] = null;
    try {
      const read = c.group === "page" || c.group === "walled" ? { page: c.page ?? null } : undefined;
      const result = await extractCard({ text: c.input }, undefined, read, (e) => {
        early_ms = Date.now() - started;
        early = e;
      }, meta);
      card = {
        title: result.title,
        kind: result.kind,
        venue: result.venue,
        category: result.category,
        starts_on: result.starts_on,
        ends_on: result.ends_on,
        url: result.url,
        website: result.website,
        image_url: result.image_url,
      };
    } catch (e) {
      const err = e as Error & { status?: number; reason?: string };
      error = {
        name: err.name ?? "Error",
        message: `${err.reason ? `${err.reason}: ` : ""}${String(err.message ?? e)}`,
        status: err.status,
      };
    }
    const ms = Date.now() - started;
    const partial = { id: c.id, group: c.group, input: c.input, ms, early_ms, early, card, meta, error };
    const checks = score(c, partial);
    outcomes.push({ ...partial, checks });
    if (c.group === "typed" || c.group === "search") {
      gate.of++;
      if ((await looksLikeSearch(c.input)) === c.expect.vague) gate.pass++;
    }
    const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([n]) => n);
    log(
      `${String(++done).padStart(3)} ${c.group.padEnd(6)} ${(ms / 1000).toFixed(1).padStart(5)}s ` +
        `${failed.length ? `✗ ${failed.join(",")}` : "✓"}  ${c.input.slice(0, 60).replace(/\n/g, " ")}` +
        (error && error.name !== "VagueInputError" ? `  [${error.name}: ${error.message.slice(0, 60)}]` : ""),
    );
  }
}
await Promise.all(Array.from({ length: Number(flag("concurrency") ?? 4) }, work));
console.log = log;

const summary = { ...summarise(label, outcomes), gate: gate.of ? gate : undefined };
await Deno.mkdir(`${DATA}/results`, { recursive: true });
await Deno.writeTextFile(`${DATA}/results/${label}.json`, JSON.stringify({ summary, outcomes }, null, 1));
log(`\n${line(summary)}`);
table([summary]);
