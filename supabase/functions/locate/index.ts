// locate: authenticated in-app endpoint. Takes saved items that have no map
// coordinates and returns proposed locations (venue/area/address + lat/lng).
// Nothing is written here — the client shows the proposals for confirmation
// and applies the accepted ones itself (RLS enforces membership).
// Auth mirrors parse: members' JWTs from the web app, or the ingest secret
// from the iOS app. Stateless — proposals are returned, never written.
import Anthropic from "npm:@anthropic-ai/sdk";
import { corsHeaders, geocode, resolveMapsLink } from "../_shared/geo.ts";
import { resolveCaller } from "../_shared/groups.ts";
import { geocodeNearHome, groupHome, type Home, homeLabel, LONDON } from "../_shared/home.ts";

interface LocateItem {
  id: string;
  kind: string;
  title: string;
  summary?: string | null;
  venue?: string | null;
  area?: string | null;
  address?: string | null;
  url?: string | null;
  notes?: string | null;
}

const schema = (home: Home) => ({
  type: "object",
  properties: {
    locations: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          venue: {
            type: ["string", "null"],
            description: "Venue or institution name",
          },
          area: {
            type: ["string", "null"],
            description: `Neighbourhood or district within its city (for ${home.locality}, the kind of name a local would use)`,
          },
          address: {
            type: ["string", "null"],
            description: `Street address, only if confidently known. Include the city when it is not ${home.locality}`,
          },
          confidence: { type: "string", enum: ["high", "medium", "low"] },
        },
        required: ["id", "venue", "area", "address", "confidence"],
        additionalProperties: false,
      },
    },
  },
  required: ["locations"],
  additionalProperties: false,
}) as const;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const secret = req.headers.get("x-ingest-secret");
    const secretOk = Boolean(secret) && secret === Deno.env.get("INGEST_SECRET");
    // JWT → group → home city (see parse). Secret alone → London.
    const caller = await resolveCaller(req);
    if (!secretOk && !caller) {
      return new Response(JSON.stringify({ error: "not in a group" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const home = caller ? await groupHome(caller.client, caller.groupId) : LONDON;
    const where = homeLabel(home);

    const body = await req.json();
    const items = (body.items ?? []) as LocateItem[];
    if (!Array.isArray(items) || items.length === 0) {
      return new Response(JSON.stringify({ error: "items required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    // Nominatim allows ~1 request/second, so keep runs bounded.
    const batch = items.slice(0, 20);
    const byId = new Map(batch.map((i) => [i.id, i]));
    const proposals = [];

    // First pass: items saved from a Google Maps link already carry an
    // exact pin in the URL — no model or geocoder needed.
    const needsModel: LocateItem[] = [];
    for (const item of batch) {
      const maps = item.url ? await resolveMapsLink(item.url) : null;
      if (maps?.lat != null && maps.lng != null) {
        // A URL stuffed into the venue field (old bad parses) isn't a venue.
        const venue =
          item.venue && !/^https?:\/\//.test(item.venue)
            ? item.venue
            : maps.name ?? item.title;
        proposals.push({
          id: item.id,
          venue,
          area: item.area ?? null,
          address: null,
          confidence: "high" as const,
          lat: maps.lat,
          lng: maps.lng,
        });
      } else {
        needsModel.push(item);
      }
    }

    // Web search + geocoding are slow; keep the model batch small so the
    // whole run fits in the edge worker's wall-clock budget. Leftovers get
    // picked up the next time the user runs it.
    const modelBatch = needsModel.slice(0, 8);
    if (modelBatch.length > 0) {
      const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
      const prompt = [
        `These are saved entries in an events/places app for someone living in ${where}; they have no map coordinates.`,
        `For each entry, work out where it is: the venue or institution name, the neighbourhood, and the street address. Most will be in ${home.locality}, but if an entry is clearly somewhere else, say where — include that city in the address rather than forcing it home.`,
        `Use what you know about real venues in ${home.locality}, and use the web search tool to confirm the street address — especially for small restaurants, cafés, and shops, where the address is what makes the entry mappable. The URL and notes often name the venue.`,
        "Titles are typed by hand and may be misspelled — if a name finds nothing, search for close spelling variants (and any names embedded in the URL) before giving up.",
        "If an entry is citywide, online-only, or genuinely unknowable, return null for all fields with confidence 'low'. Never invent an address — only return one you know or have verified by search.",
        `Entries:\n${JSON.stringify(modelBatch, null, 2)}`,
      ].join("\n\n");

      // Sonnet: address lookup doesn't need opus, and opus + web search
      // blows past the edge worker's 150s wall-clock budget.
      const response = await anthropic.messages.create({
        model: "claude-sonnet-5",
        max_tokens: 4096,
        output_config: { format: { type: "json_schema", schema: schema(home) } },
        tools: [
          { type: "web_search_20250305" as const, name: "web_search" as const, max_uses: 4 },
        ],
        messages: [{ role: "user", content: prompt }],
      });
      // Web search interleaves commentary; the JSON is the final text block.
      const textBlock = [...response.content].reverse().find((b) => b.type === "text");
      if (!textBlock || textBlock.type !== "text") {
        throw new Error("No structured output returned");
      }
      const { locations } = JSON.parse(textBlock.text) as {
        locations: {
          id: string;
          venue: string | null;
          area: string | null;
          address: string | null;
          confidence: "high" | "medium" | "low";
        }[];
      };

      for (const loc of locations) {
        let coords: { lat: number; lng: number } | null = null;
        const item = byId.get(loc.id);
        if (loc.venue || loc.area || loc.address) {
          // Addresses geocode far more reliably than small-venue names.
          if (loc.address) {
            coords = await geocodeNearHome(geocode, loc.address, home);
            await sleep(1100);
          }
          if (!coords && (loc.venue || loc.area)) {
            coords = await geocodeNearHome(
              geocode,
              [loc.venue, loc.area].filter(Boolean).join(", "),
              home,
            );
            await sleep(1100);
          }
          if (!coords && item && item.title !== loc.venue) {
            coords = await geocodeNearHome(
              geocode,
              [item.title, loc.area].filter(Boolean).join(", "),
              home,
            );
            await sleep(1100);
          }
        }
        proposals.push({
          id: loc.id,
          venue: loc.venue,
          area: loc.area,
          address: loc.address,
          confidence: loc.confidence,
          lat: coords?.lat ?? null,
          lng: coords?.lng ?? null,
        });
      }
    }

    return new Response(JSON.stringify({ proposals }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: "internal error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
