// One-time repair: fetch og:image for server items missing image_url and
// write it back (bumping updated_at so both phones pull the fix).
// Run: deno run -A scripts/backfill-image-urls.ts
import postgres from "npm:postgres@3.4.5";

const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const get = (name: string) =>
  env.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim();

const sql = postgres({
  host: "aws-1-eu-west-2.pooler.supabase.com",
  port: 5432,
  database: "postgres",
  username: `postgres.${get("SUPABASE_PROJECT_REF")}`,
  password: get("SUPABASE_DB_PASSWORD"),
  ssl: "require",
  prepare: false,
});

const UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";

const PATTERNS = [
  /<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["'][^>]+content=["']([^"']+)["']/i,
  /<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["']/i,
];

async function ogImage(pageURL: string): Promise<string | null> {
  try {
    const res = await fetch(pageURL, {
      headers: { "user-agent": UA },
      signal: AbortSignal.timeout(12000),
    });
    if (!res.ok) return null;
    const html = (await res.text()).slice(0, 400_000);
    for (const pattern of PATTERNS) {
      const raw = html.match(pattern)?.[1]?.replaceAll("&amp;", "&");
      if (raw) return new URL(raw, pageURL).href;
    }
  } catch {
    // Bot-blocked or dead page — skip.
  }
  return null;
}

const rows = await sql`
  select id, url, title from public.items
  where image_url is null and url is not null and deleted_at is null
`;
console.log(`${rows.length} items missing image_url`);

let filled = 0;
for (const row of rows) {
  if (!/^https?:/.test(row.url)) continue;
  const image = await ogImage(row.url);
  if (!image) {
    console.log(`  - ${row.title.slice(0, 45)}: none`);
    continue;
  }
  await sql`
    update public.items
    set image_url = ${image}, updated_at = now()
    where id = ${row.id}
  `;
  filled++;
  console.log(`  + ${row.title.slice(0, 45)}`);
}
await sql.end();
console.log(`filled ${filled} of ${rows.length}`);
