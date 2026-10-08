// Replay a few library saves through the parser and print where the wait
// goes: reading the page, the model call, and the lookups after it.
// Usage: deno run --allow-read --allow-env --allow-net scripts/time-parse.ts [count]
//
// Calls Claude once per save. Without GOOGLE_MAPS_API_KEY in the
// environment the Google place lookups are skipped, so lookups read low.

const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const get = (name: string) =>
  env.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim();

const url = get("SUPABASE_URL");
const key = get("SUPABASE_SERVICE_ROLE_KEY");
const anthropicKey = get("ANTHROPIC_API_KEY");
if (!url || !key || !anthropicKey) {
  console.error("Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / ANTHROPIC_API_KEY in .supabase.env");
  Deno.exit(1);
}
Deno.env.set("ANTHROPIC_API_KEY", anthropicKey);

const { extractCard } = await import("../supabase/functions/_shared/extract.ts");

const count = Number(Deno.args[0] ?? 6);
const res = await fetch(
  `${url}/rest/v1/items?deleted_at=is.null&url=not.is.null&order=created_at.desc&limit=${count}&select=title,url`,
  { headers: { apikey: key, Authorization: `Bearer ${key}` } },
);
if (!res.ok) {
  console.error(`Fetching saves failed: ${res.status} ${await res.text()}`);
  Deno.exit(1);
}
const saves = await res.json() as { title: string; url: string }[];

for (const save of saves) {
  console.log(`\n${save.title}  ${save.url}`);
  const started = Date.now();
  try {
    await extractCard({ text: save.url }, undefined, undefined, (early) => {
      console.log(`  early at ${Date.now() - started}ms: ${early.title} · ${early.venue ?? "—"} · ${early.starts_on ?? "—"}`);
    });
  } catch (e) {
    console.log(`  failed: ${e instanceof Error ? e.message : e}`);
  }
}
