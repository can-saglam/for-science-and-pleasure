// parse: stateless extraction endpoint. Takes {text?, image_base64?, image_media_type?}
// and returns a parsed card; nothing is stored. A member JWT is required —
// the home city comes from their group. The old ingest-secret path is gone.
//
// With `stream: "true"` the answer comes as server-sent events instead: an
// `early` event with the model's fields as soon as it has answered, then
// `card` once the lookups are done (or `error`, with the status it would
// have had). Builds that don't ask get the single JSON body.
//
// A lookup counts against the day's allowance only once the model has
// answered: a card, or its verdict that the input was a search. Errors,
// timeouts and unreadable posts are free.
import { internalErrorBody } from "../_shared/auth.ts";
import {
  corsHeaders,
  extractCard,
  firstUrl,
  looksLikeSearch,
  OutOfTimeError,
  type Page,
  pageFromHtml,
  pageLink,
  type ParseRun,
  readPage,
  SocialUnreadableError,
  UnreadableAnswerError,
  VagueInputError,
} from "../_shared/extract.ts";
import { assertImageWithinLimit } from "../_shared/limits.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { groupHome } from "../_shared/home.ts";
import {
  bumpVague,
  chargeQuota,
  hasQuota,
  quotaResponse,
  VAGUE_STRIKES,
  vagueStrikes,
} from "../_shared/quota.ts";

/// Everything from the request arriving to the card leaving. The phone
/// waits 120s between bytes; the edge worker is cut off at 150s.
const BUDGET_MS = 110_000;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

/// A search, not a save. `firm` (a string, so older builds still read the
/// body as strings) once the person has searched more than a few times
/// today: the app's note gets more direct.
async function vague(userId: string, message: string) {
  const strikes = await bumpVague(admin(), userId);
  return { error: message, code: "too_vague", ...(strikes > VAGUE_STRIKES ? { firm: "true" } : {}) };
}

type Outcome =
  | "card" | "vague" | "gate" | "social_unreadable" | "unreadable" | "slow" | "too_large" | "over_quota" | "error";

/// A failed extraction as the app reads it. Anything the person can act
/// on is a 422 with a sentence for them, which the app shows as is and
/// doesn't retry (see ParseClient.isTransient).
async function failure(
  e: unknown,
  userId: string | null,
): Promise<{ status: number; body: Record<string, string>; outcome: Outcome }> {
  if (e instanceof VagueInputError) {
    const body = userId ? await vague(userId, e.message) : { error: e.message, code: "too_vague" };
    return { status: 422, body, outcome: "vague" };
  }
  if (e instanceof SocialUnreadableError) {
    return { status: 422, body: { error: e.message, code: "social_unreadable" }, outcome: "social_unreadable" };
  }
  if (e instanceof UnreadableAnswerError) {
    console.warn("parse unreadable", e.reason);
    return { status: 422, body: { error: e.message, code: "unreadable" }, outcome: "unreadable" };
  }
  if (e instanceof OutOfTimeError) {
    return { status: 422, body: { error: e.message, code: "slow" }, outcome: "slow" };
  }
  console.error(e);
  return { status: 500, body: JSON.parse(internalErrorBody()), outcome: "error" };
}

/// The model answered: a card, or its word that this was a search.
const answered = (outcome: Outcome) => outcome === "card" || outcome === "vague";

function record(
  started: number,
  source: string,
  outcome: Outcome,
  run: ParseRun,
  card?: { image_url: string | null; lat: number | null },
) {
  const row = {
    source,
    route: run.route ?? null,
    outcome,
    charged: answered(outcome),
    model: run.model ?? null,
    searches: run.searches ?? null,
    input_tokens: run.input_tokens ?? null,
    output_tokens: run.output_tokens ?? null,
    stop_reason: run.stop_reason ?? null,
    read_ms: run.read_ms ?? null,
    model_ms: run.model_ms ?? null,
    lookups_ms: run.lookups_ms ?? null,
    early_ms: run.early_ms ?? null,
    total_ms: Date.now() - started,
    skipped: run.skipped?.length ? run.skipped : null,
    has_photo: card ? Boolean(card.image_url) : null,
    has_pin: card ? card.lat !== null : null,
  };
  // After the response, and never in its way.
  const write = admin().from("parse_runs").insert(row).then(({ error }) => {
    if (error) console.warn("parse_runs insert failed", error.message);
  });
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(write);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const started = Date.now();
  const run: ParseRun = { deadline: started + BUDGET_MS };
  let userId: string | null = null;
  let source = "text";
  try {
    if (!(req.headers.get("Authorization") ?? "").startsWith("Bearer ")) {
      return json({ error: "unauthorized" }, 401);
    }
    const caller = await resolveCaller(req);
    if (!caller) {
      return json({ error: "not in a group" }, 403);
    }
    userId = caller.userId;

    const body = await req.json();
    if (!body.text && !body.image_base64) {
      return json({ error: "text or image_base64 required" }, 400);
    }
    const text = typeof body.text === "string" ? body.text.trim() : "";
    source = body.image_base64 ? "image" : firstUrl(text) ? "link" : "text";

    try {
      assertImageWithinLimit(body.image_base64);
    } catch (limitErr) {
      record(started, source, "too_large", run);
      return json({ error: String(limitErr) }, 413);
    }

    if (!await hasQuota(admin(), caller.userId)) {
      record(started, source, "over_quota", run);
      return new Response(quotaResponse().body, {
        status: 429,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Typed words from someone who has already searched a few times today:
    // a quick check first, and a search is answered without a full lookup.
    // Links and pictures always go through.
    if (
      source === "text" &&
      await vagueStrikes(admin(), caller.userId) >= VAGUE_STRIKES &&
      await looksLikeSearch(text)
    ) {
      record(started, source, "gate", run);
      return json(await vague(caller.userId, new VagueInputError().message), 422);
    }

    // Some sites wall off this server but not the phone. A build that can
    // read the page itself says so and hears back before anything is
    // counted or spent, then sends the HTML: one save, read from its page
    // rather than searched for.
    const link = text ? pageLink(text) : null;
    let read: { page: Page | null } | undefined;
    if (link && typeof body.page_html === "string") {
      read = { page: pageFromHtml(body.page_html, link) };
    } else if (link && body.page_fallback === "true") {
      read = { page: await readPage(link) };
      if (!read.page) return json({ error: "page blocked", code: "page_blocked", url: link }, 409);
    }

    const home = await groupHome(caller.client, caller.groupId);
    const finish = async (outcome: Outcome, card?: { image_url: string | null; lat: number | null }) => {
      if (answered(outcome)) await chargeQuota(admin(), caller.userId, "parse");
      record(started, source, outcome, run, card);
    };

    if (body.stream === "true") {
      const encoder = new TextEncoder();
      const stream = new ReadableStream({
        async start(controller) {
          // A phone that hung up mid-read just stops hearing.
          const send = (event: string, data: unknown) => {
            try {
              controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
            } catch { /* closed */ }
          };
          try {
            const card = await extractCard(body, home, read, (early) => send("early", early), run);
            send("card", card);
            await finish("card", card);
          } catch (e) {
            const { status, body, outcome } = await failure(e, caller.userId);
            send("error", { ...body, status });
            await finish(outcome);
          }
          try {
            controller.close();
          } catch { /* closed */ }
        },
      });
      return new Response(stream, {
        headers: { ...corsHeaders, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
      });
    }

    try {
      const card = await extractCard(body, home, read, undefined, run);
      await finish("card", card);
      return json({ card });
    } catch (e) {
      const { status, body, outcome } = await failure(e, caller.userId);
      await finish(outcome);
      return json(body, status);
    }
  } catch (e) {
    const { status, body, outcome } = await failure(e, userId);
    record(started, source, outcome, run);
    return json(body, status);
  }
});
