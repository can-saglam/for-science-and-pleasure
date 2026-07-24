/**
 * Calendar/digest URL key auth.
 *
 * Prefer a dedicated FEED_SECRET so a leaked Shortcut ingest secret cannot
 * open the ICS/digest feeds. Until FEED_SECRET is set, fall back to
 * INGEST_SECRET so existing calendar subscriptions and digests keep working.
 */
export function isFeedKeyAuthorized(key: string | null): boolean {
  if (!key) return false;
  const feed = Deno.env.get("FEED_SECRET");
  if (feed) return key === feed;
  const ingest = Deno.env.get("INGEST_SECRET");
  return !!ingest && key === ingest;
}

/** Safe client-facing 500 body — log the real error server-side instead. */
export function internalErrorBody(): string {
  return JSON.stringify({ error: "internal error" });
}
