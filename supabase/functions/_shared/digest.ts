import Anthropic from "npm:@anthropic-ai/sdk";

export interface DigestItem {
  kind: "event" | "place";
  status: string;
  title: string;
  venue: string | null;
  area: string | null;
  category: string | null;
  price: string | null;
  starts_on: string | null;
  ends_on: string | null;
}

export async function generateDigestText(
  items: DigestItem[],
  today = new Date().toISOString().slice(0, 10),
): Promise<string> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const response = await anthropic.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 2048,
    messages: [
      {
        role: "user",
        content:
          `Today is ${today}. Below is a couple's shared list of saved London events (with open/close windows) and places. Write their short weekly digest for the coming week: what closes soon (urgency!), what's just opening, and one or two nice pairing ideas (event + nearby saved food/drink spot). Warm but not gushing — no pet names, no terms of endearment; address them as "you two" if needed. Concise, plain text, no markdown, under 120 words. If there is genuinely nothing relevant this week, say so in one charming sentence.\n\n` +
          JSON.stringify(items),
      },
    ],
  });

  return response.content.find((block) => block.type === "text")?.text ?? "";
}
