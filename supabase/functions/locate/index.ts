// locate: authenticated in-app endpoint. Takes saved items that have no map
// coordinates and returns proposed locations (venue/area/address + lat/lng).
// Nothing is written here — the client shows the proposals for confirmation
// and applies the accepted ones itself (RLS enforces membership).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, geocode } from "../_shared/geo.ts";

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

const SCHEMA = {
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
            description: "London neighbourhood, e.g. 'Peckham', 'South Bank'",
          },
          address: {
            type: ["string", "null"],
            description: "Street address, only if confidently known",
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
} as const;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: isMember, error: memberErr } = await supabase.rpc("is_member");
    if (memberErr || !isMember) {
      return new Response(JSON.stringify({ error: "not a member" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

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

    const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
    const prompt = [
      "These are saved entries in a London events/places app that have no map coordinates.",
      "For each entry, work out where it is: the venue or institution name, the London neighbourhood, and the street address if you are confident of it.",
      "Use what you know about real London venues, galleries, restaurants, and institutions. The URL and notes often name the venue.",
      "If an entry is citywide, online-only, or genuinely unknowable, return null for all fields with confidence 'low'. Never invent an address.",
      `Entries:\n${JSON.stringify(batch, null, 2)}`,
    ].join("\n\n");

    const response = await anthropic.messages.create({
      model: "claude-opus-4-8",
      max_tokens: 4096,
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content: prompt }],
    });
    const textBlock = response.content.find((b) => b.type === "text");
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

    const proposals = [];
    for (const loc of locations) {
      let coords: { lat: number; lng: number } | null = null;
      if (loc.venue || loc.area || loc.address) {
        if (loc.address) {
          coords = await geocode(`${loc.address}, London`);
          await sleep(1100);
        }
        if (!coords && (loc.venue || loc.area)) {
          coords = await geocode(
            [loc.venue, loc.area, "London"].filter(Boolean).join(", "),
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
