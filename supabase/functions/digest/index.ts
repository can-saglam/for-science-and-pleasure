// digest: weekly summary as short friendly text, written by Claude.
// Pull-based: a Sunday-evening iOS Shortcut automation fetches this and
// shows it as a notification (see SHORTCUT.md). Auth via ?key=.
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const key = new URL(req.url).searchParams.get("key");
  if (!key || key !== Deno.env.get("INGEST_SECRET")) {
    return new Response("unauthorized", { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: items, error } = await supabase
    .from("items")
    .select("kind, status, title, venue, area, category, price, starts_on, ends_on, planned_for")
    .is("deleted_at", null)
    .in("status", ["saved", "planned", "inbox"]);
  if (error) return new Response(String(error.message), { status: 500 });

  const today = new Date().toISOString().slice(0, 10);
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const response = await anthropic.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 2048,
    messages: [
      {
        role: "user",
        content:
          `Today is ${today}. Below is a couple's shared list of saved London events (with open/close windows) and places. Write their short weekly digest for the coming week: what's planned, what closes soon (urgency!), what's just opening, and one or two nice pairing ideas (event + nearby saved food/drink spot). Warm but not gushing — no pet names, no terms of endearment; address them as "you two" if needed. Concise, plain text, no markdown, under 120 words. If there is genuinely nothing relevant this week, say so in one charming sentence.\n\n` +
          JSON.stringify(items),
      },
    ],
  });

  const text = response.content.find((b) => b.type === "text")?.text ?? "";
  return new Response(JSON.stringify({ text }), {
    headers: { "Content-Type": "application/json" },
  });
});
