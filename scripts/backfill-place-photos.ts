// Repair: saved places with no thumbnail get one, trying the sources in
// the parser's order: the saved page's own picture, then Wikipedia, and
// Google Maps only when both come up empty. Colour is filled from the same
// picture when missing. Image-only writes leave updated_at alone (0015);
// phones pick them up on their next full pull.
// Run: deno run -A scripts/backfill-place-photos.ts [--group <uuid>] [--write]
//   Without --write it only reports what it would do.
// Needs GOOGLE_MAPS_API_KEY and SUPABASE_URL in .supabase.env or the env.
import postgres from "npm:postgres@3.4.5";
import { parseArgs } from "jsr:@std/cli@1/parse-args";
import {
  colorFromImageUrl,
  heroImageFromUrl,
  wikipediaImage,
  wikipediaQueries,
} from "../supabase/functions/_shared/color.ts";
import { homeFromRow } from "../supabase/functions/_shared/home.ts";
import { findPlace, metresBetween, photoUri, placePhotoLink } from "../supabase/functions/_shared/places.ts";

const args = parseArgs(Deno.args, { string: ["group"], boolean: ["write"] });

const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const get = (name: string) =>
  env.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim();
for (const name of ["GOOGLE_MAPS_API_KEY", "SUPABASE_URL"]) {
  if (!Deno.env.get(name) && get(name)) Deno.env.set(name, get(name)!);
}

const sql = postgres({
  host: "aws-1-eu-west-2.pooler.supabase.com",
  port: 5432,
  database: "postgres",
  username: `postgres.${get("SUPABASE_PROJECT_REF")}`,
  password: get("SUPABASE_DB_PASSWORD"),
  ssl: "require",
  prepare: false,
});

const MAPS_ICON = /(?:gstatic|googleusercontent)\.com.*maps|maps_\d+dp\.(?:png|webp)/i;

function pageWorthFetching(url: string | null): url is string {
  if (!url) return false;
  try {
    const u = new URL(url);
    const host = u.hostname.toLowerCase();
    if (!/^https?:$/.test(u.protocol)) return false;
    if (host.includes("maps.google") || host === "maps.app.goo.gl" || host === "goo.gl") return false;
    if (host.endsWith("google.com") && u.pathname.startsWith("/maps")) return false;
    return !/(^|\.)(instagram|facebook|tiktok)\.com$/.test(host);
  } catch {
    return false;
  }
}

const rows = await sql`
  select i.id, i.group_id, i.title, i.venue, i.area, i.address, i.url, i.lat, i.lng, i.color,
         g.home_locality, g.home_country, g.home_timezone, g.home_lat, g.home_lng
  from public.items i
  join public.groups g on g.id = i.group_id
  where i.kind = 'place' and i.image_url is null and i.deleted_at is null
    ${args.group ? sql`and i.group_id = ${args.group}` : sql``}
  order by i.group_id, i.title
`;
console.log(`${rows.length} places without a thumbnail${args.write ? "" : " (dry run)"}`);

const tally = { page: 0, wikipedia: 0, google: 0, none: 0 };
for (const row of rows) {
  const home = homeFromRow(row);
  let image: string | null = null;
  let source: keyof typeof tally = "none";
  let colorFrom: string | null = null;

  if (pageWorthFetching(row.url)) {
    image = await heroImageFromUrl(row.url);
    if (image && MAPS_ICON.test(image)) image = null;
    if (image) source = "page";
  }
  if (!image) {
    for (const query of wikipediaQueries(row)) {
      image = await wikipediaImage(query);
      if (image) {
        source = "wikipedia";
        break;
      }
    }
  }
  if (image) colorFrom = image;
  if (!image) {
    const place = await findPlace(row.venue ?? row.title, row, home);
    const far = place?.lat != null && place.lng != null && row.lat != null && row.lng != null &&
      metresBetween({ lat: row.lat, lng: row.lng }, { lat: place.lat, lng: place.lng }) > 1500;
    if (place?.photo && !far) {
      image = await placePhotoLink(place.id, place.credit);
      colorFrom = await photoUri(place.photo, 400);
      source = "google";
      console.log(`    matched ${place.name}, ${place.address}`);
    }
  }
  tally[source]++;
  console.log(`  ${String(row.group_id).slice(0, 8)} ${source.padEnd(9)} ${String(row.title).slice(0, 50)}`);
  if (!image || !args.write) continue;

  const color = row.color ?? (colorFrom ? await colorFromImageUrl(colorFrom).catch(() => null) : null);
  await sql`
    update public.items
    set image_url = ${image}, color = ${color}
    where id = ${row.id} and image_url is null
  `;
}
await sql.end();
console.log(tally);
