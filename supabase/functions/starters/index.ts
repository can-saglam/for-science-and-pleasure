// starters: three real things to go to in a city, for the first-run's
// save page. Body: { locality, country }. Cache first; on a miss, a
// knowledge-only model call (no web search — search is what timed out
// and came back empty). If that fails too: curated city list, then a
// stale cache. Authenticated (member JWT).
import Anthropic from "npm:@anthropic-ai/sdk";
import { corsHeaders } from "../_shared/extract.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { consumeQuota } from "../_shared/quota.ts";
import {
  STARTER_COUNT,
  type Starter,
  chooseStarters,
  fallbackStarters,
  readModelStarters,
  shapeStarters,
  starterFresh,
  starterKey,
} from "../_shared/starters.ts";

const STARTERS_SCHEMA = {
  type: "object",
  properties: {
    starters: {
      type: "array",
      description: `Exactly ${STARTER_COUNT} places`,
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "The place's own short name, under 40 characters" },
          url: { type: "string", description: "That place's own official https website" },
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

async function fromKnowledge(locality: string, country: string): Promise<Starter[]> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const response = await anthropic.messages.create({
    // No web search: a schema-only call finishes in a couple of seconds
    // and doesn't blow the edge worker's budget. Famous official sites
    // are in the model's knowledge; search was the path that came back empty.
    model: "claude-sonnet-5",
    max_tokens: 1024,
    output_config: { format: { type: "json_schema", schema: STARTERS_SCHEMA } },
    messages: [{
      role: "user",
      content:
        `Name ${STARTER_COUNT} real, well-known places in ${locality}, ${country} that someone would go to. ` +
        `Need one restaurant, café or bar; one gallery, museum, music venue or cinema; and one more of either. ` +
        `Each url MUST be that place's own official https website — a domain you are sure exists. ` +
        `Never google, maps, tripadvisor, timeout, wikipedia, instagram, facebook, eventbrite, dice, songkick, or a city tourism portal. ` +
        `If you are not sure of a domain, pick a better-known place whose official site you are sure of. ` +
        `Titles are the place's own short name, in the local spelling.`,
    }],
  });
  return shapeStarters(readModelStarters(response.content));
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
    const fallback = fallbackStarters(locality, country);
    const { data: cached } = await db
      .from("starter_cache")
      .select("payload, fetched_at")
      .eq("key", key)
      .maybeSingle();
    const stale = cached ? shapeStarters(cached.payload) : [];
    if (cached && starterFresh(cached.fetched_at) && stale.length > 0) {
      return json({ starters: stale, cached: true });
    }

    let shaped: Starter[] = [];
    if (await consumeQuota(db, caller.userId, "suggest")) {
      try {
        shaped = await fromKnowledge(locality, country);
      } catch (error) {
        console.error("starters model", error);
      }
    }

    const starters = chooseStarters(shaped, fallback, stale);
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
