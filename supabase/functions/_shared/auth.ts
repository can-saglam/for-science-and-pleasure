/** Calendar URL key auth: only FEED_SECRET opens a feed. */
export function isFeedKeyAuthorized(key: string | null): boolean {
  if (!key) return false;
  const feed = Deno.env.get("FEED_SECRET");
  return !!feed && key === feed;
}

/** Safe client-facing 500 body — log the real error server-side instead. */
export function internalErrorBody(): string {
  return JSON.stringify({ error: "internal error" });
}
