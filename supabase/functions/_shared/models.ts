import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";

/// One structured answer from whichever provider serves the model: OpenAI
/// for gpt-*, Google for gemini-*, Claude for the rest. A name may end in
/// @<effort> (gpt-6-sol@low, gemini-3.8-flash@medium) for how hard the
/// model thinks. The parse runs on Claude; the others are here so
/// scripts/parse-eval can try them on the same prompts.
export interface Ask {
  model: string;
  system?: string;
  text: string;
  image?: { media_type: string; data: string } | null;
  /** Lets the model search the web, up to three times. */
  search?: boolean;
  schema: Record<string, unknown>;
  max_tokens: number;
  signal?: AbortSignal;
  /** Tries after the first, for an overloaded or failed call. */
  retries?: number;
}

export interface Answer {
  /** The last text the model wrote: the JSON the schema asked for. */
  text: string | null;
  /** It ended on its own, rather than cut off, refused or mid-search. */
  finished: boolean;
  stop: string;
  /** Every URL the search showed the model. */
  sources: string[];
  input_tokens: number;
  output_tokens: number;
  /** Billable search calls. */
  searches: number;
}

/// Thrown, under the name callers already catch, when the signal ends a call.
const timedOut = () => new DOMException("The model call ran out of time", "TimeoutError");

export function ask(a: Ask): Promise<Answer> {
  const [model, effort] = a.model.split("@");
  if (model.startsWith("gpt-")) return openai(a, model, effort);
  if (model.startsWith("gemini-")) return gemini(a, model, effort);
  return claude(a, model);
}

async function claude(a: Ask, model: string): Promise<Answer> {
  const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY"), maxRetries: a.retries ?? 1 });
  const content: Anthropic.ContentBlockParam[] = [];
  if (a.image) {
    content.push({
      type: "image",
      source: { type: "base64", media_type: a.image.media_type as "image/jpeg", data: a.image.data },
    });
  }
  content.push({ type: "text", text: a.text });
  const messages: Anthropic.MessageParam[] = [{ role: "user", content }];
  const out: Answer = { text: null, finished: false, stop: "unknown", sources: [], input_tokens: 0, output_tokens: 0, searches: 0 };
  // A long search turn can pause partway; carrying on once finishes it.
  for (let turn = 0; turn < 2; turn++) {
    let reply: Anthropic.Message;
    try {
      reply = await client.messages.create({
        model,
        max_tokens: a.max_tokens,
        ...(a.system ? { system: a.system } : {}),
        output_config: { format: { type: "json_schema", schema: a.schema } },
        ...(a.search
          ? { tools: [{ type: "web_search_20250305" as const, name: "web_search" as const, max_uses: 3 }] }
          : {}),
        messages,
      }, a.signal ? { signal: a.signal } : {});
    } catch (e) {
      if (e instanceof Anthropic.APIUserAbortError) throw timedOut();
      throw e;
    }
    out.input_tokens += reply.usage?.input_tokens ?? 0;
    out.output_tokens += reply.usage?.output_tokens ?? 0;
    out.searches += reply.usage?.server_tool_use?.web_search_requests ?? 0;
    out.stop = reply.stop_reason ?? "unknown";
    for (const block of reply.content) {
      if (block.type === "web_search_tool_result" && Array.isArray(block.content)) {
        for (const result of block.content) out.sources.push(result.url);
      }
    }
    // With web search the model may write commentary between searches;
    // the structured JSON is always the final text block.
    const last = [...reply.content].reverse().find((b) => b.type === "text");
    out.text = last?.type === "text" ? last.text : null;
    if (reply.stop_reason !== "pause_turn") break;
    messages.push({ role: "assistant", content: reply.content });
  }
  out.finished = out.stop === "end_turn";
  return out;
}

/// The Responses API, with its hosted web search.
async function openai(a: Ask, model: string, effort?: string): Promise<Answer> {
  const res = await post("https://api.openai.com/v1/responses", {
    Authorization: `Bearer ${Deno.env.get("OPENAI_API_KEY")}`,
  }, {
    model,
    ...(a.system ? { instructions: a.system } : {}),
    input: [{
      role: "user",
      content: [
        ...(a.image ? [{ type: "input_image", image_url: `data:${a.image.media_type};base64,${a.image.data}` }] : []),
        { type: "input_text", text: a.text },
      ],
    }],
    text: { format: { type: "json_schema", name: "answer", schema: a.schema, strict: true } },
    max_output_tokens: a.max_tokens,
    ...(effort ? { reasoning: { effort } } : {}),
    ...(a.search ? { tools: [{ type: "web_search" }], include: ["web_search_call.action.sources"] } : {}),
    store: false,
  }, a);
  const out: Answer = {
    text: null,
    finished: false,
    stop: res.status === "completed" ? "end_turn" : res.incomplete_details?.reason ?? res.status ?? "unknown",
    sources: [],
    input_tokens: res.usage?.input_tokens ?? 0,
    output_tokens: res.usage?.output_tokens ?? 0,
    searches: 0,
  };
  for (const item of res.output ?? []) {
    if (item.type === "web_search_call") {
      out.searches++;
      if (item.action?.url) out.sources.push(item.action.url);
      for (const s of item.action?.sources ?? []) if (s.url) out.sources.push(s.url);
    }
    if (item.type !== "message") continue;
    for (const c of item.content ?? []) {
      if (c.type === "refusal") out.stop = "refusal";
      if (c.type !== "output_text") continue;
      out.text = c.text;
      for (const n of c.annotations ?? []) if (n.url) out.sources.push(n.url);
    }
  }
  out.finished = out.stop === "end_turn";
  return out;
}

/// generateContent, grounded with Google Search.
async function gemini(a: Ask, model: string, effort?: string): Promise<Answer> {
  const res = await post(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
    { "x-goog-api-key": Deno.env.get("GEMINI_API_KEY") ?? "" },
    {
      ...(a.system ? { systemInstruction: { parts: [{ text: a.system }] } } : {}),
      contents: [{
        role: "user",
        parts: [
          ...(a.image ? [{ inlineData: { mimeType: a.image.media_type, data: a.image.data } }] : []),
          { text: a.text },
        ],
      }],
      ...(a.search ? { tools: [{ google_search: {} }] } : {}),
      generationConfig: {
        responseMimeType: "application/json",
        responseJsonSchema: a.schema,
        maxOutputTokens: a.max_tokens,
        ...(effort ? { thinkingConfig: { thinkingLevel: effort } } : {}),
      },
    },
    a,
  );
  const candidate = res.candidates?.[0];
  const parts: { text?: string; thought?: boolean }[] = candidate?.content?.parts ?? [];
  const text = parts.filter((p) => typeof p.text === "string" && !p.thought).map((p) => p.text).join("");
  const grounding = candidate?.groundingMetadata;
  const usage = res.usageMetadata ?? {};
  const stop = candidate?.finishReason === "STOP" ? "end_turn" : candidate?.finishReason ?? res.promptFeedback?.blockReason ?? "unknown";
  return {
    text: text || null,
    finished: stop === "end_turn",
    stop,
    sources: await unredirect((grounding?.groundingChunks ?? []).map((c: { web?: { uri?: string } }) => c.web?.uri).filter(Boolean)),
    input_tokens: (usage.promptTokenCount ?? 0) + (usage.toolUsePromptTokenCount ?? 0),
    output_tokens: (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0),
    searches: grounding?.webSearchQueries?.length ?? 0,
  };
}

/// Google's grounding sources arrive as its own redirect links; where each
/// one lands is the page the model saw.
function unredirect(urls: string[]): Promise<string[]> {
  return Promise.all(urls.map(async (url) => {
    if (!url.includes("grounding-api-redirect")) return url;
    try {
      const res = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(3_000) });
      await res.body?.cancel();
      return res.headers.get("location") ?? url;
    } catch {
      return url;
    }
  }));
}

// deno-lint-ignore no-explicit-any
async function post(url: string, headers: Record<string, string>, body: unknown, a: Ask): Promise<any> {
  for (let attempt = 0; ; attempt++) {
    let res: Response;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: JSON.stringify(body),
        signal: a.signal,
      });
    } catch (e) {
      if (a.signal?.aborted) throw timedOut();
      if (attempt >= (a.retries ?? 1)) throw e;
      continue;
    }
    if (res.ok) return await res.json();
    const detail = (await res.text()).slice(0, 300);
    if (attempt >= (a.retries ?? 1) || !(res.status === 429 || res.status >= 500)) {
      throw Object.assign(new Error(`${new URL(url).hostname} ${res.status}: ${detail}`), { status: res.status });
    }
    await new Promise((r) => setTimeout(r, 1_000));
  }
}
