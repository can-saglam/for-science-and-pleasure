// starters: three real things to go to in a city, for the first-run's
// save page. Body: { locality, country }. One web-search model call per
// city, cached in starter_cache for two weeks; a cache hit costs nothing
// and returns at once. Authenticated (member JWT) — every account has a
// group from sign-up, so a brand new person qualifies.
import Anthropic from "npm:@anthropic-ai/sdk";
import { corsHeaders } from "../_shared/extract.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { consumeQuota } from "../_shared/quota.ts";
import {
  STARTER_COUNT,
  type Starter,
  shapeStarters,
  starterFresh,
  starterKey,
} from "../_shared/starters.ts";

const STARTERS_SCHEMA = {
  type: "object",
  properties: {
    starters: {
      type: "array",
      description: `${STARTER_COUNT} to 5 candidates`,
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "The venue or event's own short name, under 40 characters" },
          url: { type: "string", description: "The venue or event's OWN official https page" },
          kind: { type: "string", enum: ["event", "place"] },
        },
        required: ["title", "url", "kind"],
        additionalProperties: false,
      },
    },
  },
  required: ["starters"],
  additionalProperties: false,
} as const;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const caller = await resolveCaller(req);
    if (!caller) return json({ error: "not in a group" }, 403);

    const body = await req.json().catch(() => ({}));
    const locality = typeof body.locality === "string" ? body.locality.trim() : "";
    const country = typeof body.country === "string" ? body.country.trim() : "";
    if (!locality || !country || locality.length > 80 || country.length > 80) {
      return json({ error: "locality and country required" }, 400);
    }

    const db = admin();
    const key = starterKey(locality, country);
    const { data: cached } = await db
      .from("starter_cache")
      .select("payload, fetched_at")
      .eq("key", key)
      .maybeSingle();
    if (cached && starterFresh(cached.fetched_at)) {
      return json({ starters: shapeStarters(cached.payload), cached: true });
    }

    // A miss costs a model call: count it against the same daily cap as
    // day plans, so a scripted client can't run up the bill city by city.
    if (!await consumeQuota(db, caller.userId, "suggest")) {
      return json({ error: "daily limit reached" }, 429);
    }

    const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
    const today = new Date().toISOString().slice(0, 10);
    const response = await anthropic.messages.create({
      // Sonnet with search: quick enough for the edge worker's budget.
      model: "claude-sonnet-5",
      max_tokens: 2048,
      output_config: { format: { type: "json_schema", schema: STARTERS_SCHEMA } },
      tools: [{ type: "web_search_20250305" as const, name: "web_search" as const, max_uses: 3 }],
      messages: [{
        role: "user",
        content:
          `Someone has just moved to, or lives in, ${locality}, ${country}. Today is ${today}. ` +
          `Suggest ${STARTER_COUNT} to 5 well-known, currently open things they might want to go to there, ` +
          `mixing kinds: one exhibition, show or festival that is on now or opening within two months (kind "event"), ` +
          `one much-loved restaurant, café or bar (kind "place"), and one landmark venue — a gallery, museum, music venue or independent cinema (kind "place"). ` +
          `Each must be a specific, real place or event in ${locality} with its OWN official website page (the venue's or event's own domain — never a listings, ticketing, review, map or social site). ` +
          `Prefer places with a strong following among locals over tourist traps. Titles are the thing's own name, in the local spelling.`,
      }],
    });

    const textBlock = [...response.content].reverse().find((b) => b.type === "text");
    const raw = textBlock && textBlock.type === "text" ? JSON.parse(textBlock.text) : { starters: [] };
    const starters: Starter[] = shapeStarters(raw);

    if (starters.length > 0) {
      await db.from("starter_cache").upsert({
        key,
        locality,
        country,
        payload: { starters },
        fetched_at: new Date().toISOString(),
      });
    }
    return json({ starters, cached: false });
  } catch (e) {
    console.error(e);
    return json({ error: "internal error" }, 500);
  }
});
