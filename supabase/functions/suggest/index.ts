// suggest: "free on Saturday?" — Claude proposes 2-3 day plans from the
// couple's own library for a given date. Authenticated (member JWT).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/extract.ts";

const PLANS_SCHEMA = {
  type: "object",
  properties: {
    plans: {
      type: "array",
      description: "1-3 distinct plans for the day",
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "Short catchy name for the plan" },
          why: { type: "string", description: "One sentence on why this plan, mentioning urgency (closing soon) when relevant" },
          item_ids: {
            type: "array",
            items: { type: "string" },
            description: "ids of the saved items used in this plan",
          },
          steps: {
            type: "array",
            items: { type: "string" },
            description: "2-4 ordered steps, e.g. 'Morning: X at Y', 'Lunch: Z nearby'",
          },
        },
        required: ["title", "why", "item_ids", "steps"],
        additionalProperties: false,
      },
    },
  },
  required: ["plans"],
  additionalProperties: false,
} as const;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: isMember } = await supabase.rpc("is_member");
    if (!isMember) {
      return new Response(JSON.stringify({ error: "not a member" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { date } = await req.json();
    if (!date) {
      return new Response(JSON.stringify({ error: "date required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // RLS-scoped read via the caller's JWT
    const { data: items, error } = await supabase
      .from("items")
      .select("id, kind, status, title, venue, area, category, price, starts_on, ends_on, lat, lng")
      .is("deleted_at", null)
      .in("status", ["saved", "planned"]);
    if (error) throw error;

    const relevant = (items ?? []).filter((i) => {
      if (i.kind === "place") return true;
      const opens = i.starts_on ?? i.ends_on;
      const closes = i.ends_on ?? i.starts_on;
      if (!opens && !closes) return true;
      return (!opens || opens <= date) && (!closes || closes >= date);
    });

    const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
    const response = await anthropic.messages.create({
      model: "claude-opus-4-8",
      max_tokens: 4096,
      output_config: { format: { type: "json_schema", schema: PLANS_SCHEMA } },
      messages: [
        {
          role: "user",
          content:
            `A couple in London is free on ${date} and wants day-plan ideas built ONLY from their own saved list below (coordinates included where known — use them to keep each plan geographically sensible and walkable). Prioritise events that close soon after ${date}. Combine an event with a nearby saved food/drink/cafe spot where possible. Propose 1-3 distinct plans.\n\n` +
            JSON.stringify(relevant),
        },
      ],
    });

    const textBlock = response.content.find((b) => b.type === "text");
    const plans = textBlock && textBlock.type === "text" ? JSON.parse(textBlock.text) : { plans: [] };
    return new Response(JSON.stringify(plans), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
