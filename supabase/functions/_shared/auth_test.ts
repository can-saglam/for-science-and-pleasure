import { isFeedKeyAuthorized } from "./auth.ts";

function withEnv(vars: Record<string, string | null>, fn: () => void) {
  const previous = new Map<string, string | undefined>();
  for (const key of Object.keys(vars)) {
    previous.set(key, Deno.env.get(key));
    const value = vars[key];
    if (value === null) Deno.env.delete(key);
    else Deno.env.set(key, value);
  }
  try {
    fn();
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}

Deno.test("feed auth falls back to INGEST_SECRET when FEED_SECRET unset", () => {
  withEnv({ FEED_SECRET: null, INGEST_SECRET: "ingest-only" }, () => {
    if (!isFeedKeyAuthorized("ingest-only")) {
      throw new Error("expected ingest secret to authorize");
    }
    if (isFeedKeyAuthorized("wrong")) {
      throw new Error("expected wrong key to fail");
    }
    if (isFeedKeyAuthorized(null)) {
      throw new Error("expected null key to fail");
    }
  });
});

Deno.test("feed auth prefers FEED_SECRET when set", () => {
  withEnv({ FEED_SECRET: "feed-key", INGEST_SECRET: "ingest-only" }, () => {
    if (!isFeedKeyAuthorized("feed-key")) {
      throw new Error("expected feed secret to authorize");
    }
    if (isFeedKeyAuthorized("ingest-only")) {
      throw new Error("ingest secret must not authorize once FEED_SECRET is set");
    }
  });
});
