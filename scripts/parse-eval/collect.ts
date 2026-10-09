// Builds the parser's test set from the library: every save that still
// stands (a place, or an event not yet over) becomes a case whose expected
// answer is the save as it is now, hand corrections included. Each linked
// page is read once here and kept, so later runs give the model the same
// page and a score moves only when the parser does.
// Usage: deno run --allow-read --allow-write --allow-env --allow-net scripts/parse-eval/collect.ts
//
// Writes scripts/parse-eval/data/cases.json, which holds library content
// and stays out of git. Handwritten cases live in typed.json beside this.

import { firstUrl, type Page, pageFromHtml } from "../../supabase/functions/_shared/extract.ts";
import type { Case } from "./score.ts";

const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const get = (name: string) => env.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim();
const url = get("SUPABASE_URL");
const key = get("SUPABASE_SERVICE_ROLE_KEY");
if (!url || !key) {
  console.error("Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in .supabase.env");
  Deno.exit(1);
}

interface Save {
  id: string;
  kind: "event" | "place";
  title: string;
  venue: string | null;
  category: string | null;
  starts_on: string | null;
  ends_on: string | null;
  url: string | null;
  image_url: string | null;
  source: string;
  raw_input: string | null;
}

const res = await fetch(
  `${url}/rest/v1/items?deleted_at=is.null&order=created_at.desc&limit=1000` +
    "&select=id,kind,title,venue,category,starts_on,ends_on,url,image_url,source,raw_input",
  { headers: { apikey: key, Authorization: `Bearer ${key}` } },
);
if (!res.ok) {
  console.error(`Fetching saves failed: ${res.status} ${await res.text()}`);
  Deno.exit(1);
}
const saves = await res.json() as Save[];
const today = new Date().toISOString().slice(0, 10);

const MAPS = /^(maps\.app\.goo\.gl|goo\.gl|g\.co)$|(^|\.)google\.[a-z.]+$/i;
const SOCIAL = /(^|\.)(instagram\.com|tiktok\.com|facebook\.com)$/i;

async function snapshot(link: string): Promise<Page | null> {
  try {
    const res = await fetch(link, {
      redirect: "follow",
      signal: AbortSignal.timeout(15_000),
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml",
      },
    });
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    return pageFromHtml(await res.text(), res.url || link);
  } catch {
    return null;
  }
}

const cases: Case[] = [];
for (const save of saves) {
  // An event that's over, or has no dates to check against, says nothing
  // about what the parser should answer today.
  const last = save.ends_on ?? save.starts_on;
  if (save.kind === "event" && (!last || last < today)) continue;
  const expect: Case["expect"] = {
    vague: false,
    kind: save.kind,
    title: save.title,
    venue: save.venue,
    category: save.category,
    starts_on: save.kind === "event" ? save.starts_on : null,
    ends_on: save.kind === "event" ? save.ends_on : null,
    photo: Boolean(save.image_url),
  };
  const typed = save.source === "text" && save.raw_input && !firstUrl(save.raw_input);
  if (typed) {
    const host = save.url ? new URL(save.url).hostname.replace(/^www\./, "") : null;
    cases.push({ id: save.id, group: "typed", input: save.raw_input!.trim(), expect: { ...expect, host } });
    continue;
  }
  if (!save.url) continue;
  const host = new URL(save.url).hostname.replace(/^www\./, "");
  if (MAPS.test(host)) {
    cases.push({ id: save.id, group: "maps", input: save.url, expect });
  } else if (SOCIAL.test(host)) {
    cases.push({ id: save.id, group: "social", input: save.url, expect });
  } else {
    const page = await snapshot(save.url);
    cases.push({ id: save.id, group: page ? "page" : "walled", input: save.url, page, expect });
    console.log(`${page ? "read  " : "walled"} ${save.url}`);
    // Few saved pages wall off a server, so some readable ones also run as
    // if they did: the route where the parser searches instead.
    if (page && cases.filter((c) => c.group === "page").length % 5 === 0) {
      cases.push({ id: `${save.id}-walled`, group: "walled", input: save.url, page: null, expect });
    }
  }
}

await Deno.mkdir("scripts/parse-eval/data", { recursive: true });
await Deno.writeTextFile("scripts/parse-eval/data/cases.json", JSON.stringify({ collected: today, cases }, null, 1));
const groups = Object.entries(Object.groupBy(cases, (c) => c.group)).map(([g, list]) => `${g} ${list!.length}`);
console.log(`\n${cases.length} cases: ${groups.join(", ")}`);
