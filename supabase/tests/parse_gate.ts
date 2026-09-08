// Parse-quality gate (launch plan, Phase 1a).
//
// Replays a sample of the library's saved URLs through the *local* copy of
// the extractor (supabase/functions/_shared/extract.ts) with a given home,
// and diffs the resulting cards against what's stored. The prompt change
// from "a London app" to "the user lives in {home}" ships only when the
// diff against production (home = London) is noise: the same title, dates
// and venue, coordinates within a few hundred metres.
//
//   deno run -A supabase/tests/parse_gate.ts                # 12 random London URLs
//   deno run -A supabase/tests/parse_gate.ts --n 20 --seed 7
//   deno run -A supabase/tests/parse_gate.ts --home "Lisbon|Portugal|Europe/Lisbon" \
//       --url https://... --url https://...                 # spot-check another home
//
// Reads .supabase.env at the repo root (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
// ANTHROPIC_API_KEY). Costs real model calls: ~£0.05–0.20 per URL.
import { parseArgs } from "jsr:@std/cli@1/parse-args";
import { extractCard } from "../functions/_shared/extract.ts";
import { type Home, LONDON } from "../functions/_shared/home.ts";

const args = parseArgs(Deno.args, {
  string: ["n", "seed", "home", "url", "concurrency"],
  collect: ["url"],
  boolean: ["social"],
});

// --- env -------------------------------------------------------------------
const envPath = new URL("../../.supabase.env", import.meta.url);
for (const line of (await Deno.readTextFile(envPath)).split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?(.*?)"?\s*$/);
  if (m && !Deno.env.get(m[1])) Deno.env.set(m[1], m[2]);
}
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// --- home -----------------------------------------------------------------
let home: Home = LONDON;
if (args.home) {
  const [locality, country, timezone] = args.home.split("|");
  home = { locality, country, timezone: timezone ?? "UTC", lat: null, lng: null };
}

// --- sample ---------------------------------------------------------------
interface Stored {
  id: string;
  title: string;
  kind: string;
  venue: string | null;
  area: string | null;
  address: string | null;
  price: string | null;
  starts_on: string | null;
  ends_on: string | null;
  url: string;
  lat: number | null;
  lng: number | null;
}

function rng(seed: number) {
  let s = seed >>> 0 || 1;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

const SOCIAL = /instagram\.com|tiktok\.com|facebook\.com/i;

let sample: Stored[];
if (args.url.length > 0) {
  sample = args.url.map((u, i) => ({
    id: `arg-${i}`, title: "", kind: "", venue: null, area: null, address: null,
    price: null, starts_on: null, ends_on: null, url: u, lat: null, lng: null,
  }));
} else {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/items?select=id,title,kind,venue,area,address,price,starts_on,ends_on,url,lat,lng&deleted_at=is.null&url=not.is.null`,
    { headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } },
  );
  const all = (await res.json()) as Stored[];
  const pool = all.filter((i) => i.url?.startsWith("http") && (args.social || !SOCIAL.test(i.url)));
  const rand = rng(Number(args.seed ?? Date.now() % 100000));
  const shuffled = pool.map((x) => [rand(), x] as const).sort((a, b) => a[0] - b[0]).map(([, x]) => x);
  sample = shuffled.slice(0, Number(args.n ?? 12));
}

// --- compare ---------------------------------------------------------------
const norm = (s: string | null | undefined) =>
  (s ?? "").toLowerCase().replace(/[‘’'"“”.,:;!?()\-–—]/g, " ").replace(/\s+/g, " ").trim();

function km(a: Stored, lat: number | null, lng: number | null): number | null {
  if (a.lat == null || a.lng == null || lat == null || lng == null) return null;
  const R = 6371, d2r = Math.PI / 180;
  const dLat = (lat - a.lat) * d2r, dLng = (lng - a.lng) * d2r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * d2r) * Math.cos(lat * d2r) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

interface Row {
  url: string;
  stored: Stored;
  card?: Awaited<ReturnType<typeof extractCard>>;
  error?: string;
  ms: number;
}

async function run(s: Stored): Promise<Row> {
  const t0 = Date.now();
  try {
    const card = await extractCard({ text: s.url }, home);
    return { url: s.url, stored: s, card, ms: Date.now() - t0 };
  } catch (e) {
    return { url: s.url, stored: s, error: String(e), ms: Date.now() - t0 };
  }
}

// Modest concurrency: Nominatim wants ~1 req/s and the extractor doesn't
// pace itself; two at a time keeps geocoding honest.
const concurrency = Number(args.concurrency ?? 2);
const rows: Row[] = [];
let next = 0;
await Promise.all(
  Array.from({ length: concurrency }, async () => {
    while (next < sample.length) {
      const s = sample[next++];
      console.error(`… ${s.title || s.url}`);
      rows.push(await run(s));
    }
  }),
);

// --- report ----------------------------------------------------------------
const flag = (ok: boolean) => (ok ? "  " : "!!");
let clean = 0, soft = 0, hard = 0, failed = 0;

console.log(`\nParse gate — home = ${home.locality}, ${home.country} — ${rows.length} URLs\n`);
for (const r of rows.sort((a, b) => a.stored.title.localeCompare(b.stored.title))) {
  console.log(`━━ ${r.stored.title || r.url}`);
  console.log(`   ${r.url}`);
  if (!r.card) {
    failed++;
    console.log(`   FAILED (${(r.ms / 1000).toFixed(0)}s): ${r.error}`);
    continue;
  }
  const c = r.card, s = r.stored;
  if (!s.title) {
    // Spot-check mode: just print the card.
    console.log(`   → ${c.kind} · ${c.title} · ${c.venue ?? "—"} · ${c.area ?? "—"} · ${c.address ?? "—"}`);
    console.log(`     ${c.starts_on ?? "—"} → ${c.ends_on ?? "—"} · ${c.price ?? "—"} · ${c.lat?.toFixed(4) ?? "—"},${c.lng?.toFixed(4) ?? "—"} (${(r.ms / 1000).toFixed(0)}s)`);
    continue;
  }
  const titleOk = norm(c.title) === norm(s.title) || norm(c.title).includes(norm(s.title)) || norm(s.title).includes(norm(c.title));
  const kindOk = c.kind === s.kind;
  const datesOk = (c.starts_on ?? null) === (s.starts_on ?? null) && (c.ends_on ?? null) === (s.ends_on ?? null);
  const venueOk = !s.venue || !c.venue || norm(c.venue) === norm(s.venue) || norm(c.venue).includes(norm(s.venue)) || norm(s.venue).includes(norm(c.venue));
  const areaOk = !s.area || !c.area || norm(c.area) === norm(s.area);
  const priceOk = !s.price || !c.price || norm(c.price) === norm(s.price);
  const dist = km(s, c.lat, c.lng);
  const coordsOk = dist === null || dist < 0.75;

  const hardIssues = [!titleOk && "title", !kindOk && "kind", !datesOk && "dates", dist !== null && dist >= 5 && "coords>5km"].filter(Boolean);
  const softIssues = [!venueOk && "venue", !areaOk && "area", !priceOk && "price", !coordsOk && dist !== null && dist < 5 && "coords"].filter(Boolean);
  if (hardIssues.length) hard++;
  else if (softIssues.length) soft++;
  else clean++;

  console.log(`   ${flag(titleOk)} title   ${s.title}${titleOk ? "" : `  →  ${c.title}`}`);
  console.log(`   ${flag(kindOk)} kind    ${s.kind}${kindOk ? "" : `  →  ${c.kind}`}`);
  console.log(`   ${flag(datesOk)} dates   ${s.starts_on ?? "—"} → ${s.ends_on ?? "—"}${datesOk ? "" : `  ⇢  ${c.starts_on ?? "—"} → ${c.ends_on ?? "—"}`}`);
  console.log(`   ${flag(venueOk)} venue   ${s.venue ?? "—"}${venueOk ? "" : `  →  ${c.venue ?? "—"}`}`);
  console.log(`   ${flag(areaOk)} area    ${s.area ?? "—"}${areaOk ? "" : `  →  ${c.area ?? "—"}`}`);
  console.log(`   ${flag(priceOk)} price   ${s.price ?? "—"}${priceOk ? "" : `  →  ${c.price ?? "—"}`}`);
  console.log(`   ${flag(coordsOk)} coords  ${dist === null ? (s.lat == null ? "(none stored)" : c.lat == null ? "(none parsed)" : "") : `${(dist * 1000).toFixed(0)} m apart`}`);
  console.log(`      address ${c.address ?? "—"} · ${(r.ms / 1000).toFixed(0)}s`);
}

if (rows.some((r) => r.stored.title)) {
  console.log(`\n${clean} clean · ${soft} soft (venue/area/price wording, coords <5 km) · ${hard} hard (title/kind/dates/coords ≥5 km) · ${failed} failed`);
  console.log(hard === 0 ? "GATE: pass — differences are noise" : "GATE: look at the hard rows before shipping");
}
