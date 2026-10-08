// parse: stateless extraction endpoint. Takes {text?, image_base64?, image_media_type?}
// and returns a parsed card; nothing is stored. A member JWT is required —
// the home city comes from their group. The old ingest-secret path is gone.
//
// With `stream: "true"` the answer comes as server-sent events instead: an
// `early` event with the model's fields as soon as it has answered, then
// `card` once the lookups are done (or `error`, with the status it would
// have had). Builds that don't ask get the single JSON body.
import { internalErrorBody } from "../_shared/auth.ts";
import {
  corsHeaders,
  extractCard,
  firstUrl,
  looksLikeSearch,
  type Page,
  pageFromHtml,
  pageLink,
  readPage,
  SocialUnreadableError,
  VagueInputError,
} from "../_shared/extract.ts";
import { assertImageWithinLimit } from "../_shared/limits.ts";
import { admin, resolveCaller } from "../_shared/groups.ts";
import { groupHome } from "../_shared/home.ts";
import { bumpVague, consumeQuota, quotaResponse, VAGUE_STRIKES, vagueStrikes } from "../_shared/quota.ts";

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

/// A failed extraction as the app reads it. A social post nothing could
/// read is a question for the user, not a server error: 422 so the app
/// shows the message as-is (and doesn't retry — see ParseClient.isTransient).
async function failure(e: unknown, userId: string | null): Promise<{ status: number; body: Record<string, string> }> {
  if (e instanceof VagueInputError && userId) {
    return { status: 422, body: await vague(userId, e.message) };
  }
  if (e instanceof SocialUnreadableError || e instanceof VagueInputError) {
    const code = e instanceof VagueInputError ? "too_vague" : "social_unreadable";
    return { status: 422, body: { error: e.message, code } };
  }
  console.error(e);
  return { status: 500, body: JSON.parse(internalErrorBody()) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  let userId: string | null = null;
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

    // Typed words from someone who has already searched a few times today:
    // a quick check first, and a search is answered without a full lookup.
    // Links and pictures always go through.
    const text = typeof body.text === "string" ? body.text.trim() : "";
    if (
      text && !body.image_base64 && !firstUrl(text) &&
      await vagueStrikes(admin(), caller.userId) >= VAGUE_STRIKES &&
      await looksLikeSearch(text)
    ) {
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

    if (!await consumeQuota(admin(), caller.userId, "parse")) {
      return new Response(quotaResponse().body, {
        status: 429,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const home = await groupHome(caller.client, caller.groupId);

    try {
      assertImageWithinLimit(body.image_base64);
    } catch (limitErr) {
      return json({ error: String(limitErr) }, 413);
    }

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
            const card = await extractCard(body, home, read, (early) => send("early", early));
            send("card", card);
          } catch (e) {
            const { status, body } = await failure(e, caller.userId);
            send("error", { ...body, status });
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

    const card = await extractCard(body, home, read);
    return json({ card });
  } catch (e) {
    const { status, body } = await failure(e, userId);
    return json(body, status);
  }
});
