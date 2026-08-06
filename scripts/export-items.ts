// Export all items from Supabase into the iOS app's seed file.
// Usage: deno run --allow-read --allow-write --allow-net scripts/export-items.ts
//
// The output is gitignored (personal data in a public repo). Bundle it by
// building the app after running this — the file lands inside ios/CanWeGo/
// Resources, which Xcode picks up automatically.

const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const get = (name: string) =>
  env.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim();

const url = get("SUPABASE_URL");
const key = get("SUPABASE_SERVICE_ROLE_KEY");
if (!url || !key) {
  console.error("Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in .supabase.env");
  Deno.exit(1);
}

const res = await fetch(
  `${url}/rest/v1/items?deleted_at=is.null&order=created_at.asc&select=` +
    "id,kind,title,summary,venue,area,address,url,image_url,starts_on,ends_on," +
    "price,category,notes,status,color,lat,lng,added_by_email,created_at,updated_at",
  { headers: { apikey: key, Authorization: `Bearer ${key}` } },
);
if (!res.ok) {
  console.error(`Export failed: ${res.status} ${await res.text()}`);
  Deno.exit(1);
}

const items = await res.json();
const out = "ios/CanWeGo/Resources/seed-items.json";
await Deno.mkdir("ios/CanWeGo/Resources", { recursive: true });
await Deno.writeTextFile(out, JSON.stringify(items, null, 2));
console.log(`Wrote ${items.length} items to ${out}`);
