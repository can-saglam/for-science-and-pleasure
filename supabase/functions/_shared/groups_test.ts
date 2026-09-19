// Group helpers against a stub Supabase client: the fallbacks and the
// exclusion logic are what a wrong line would silently break.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { displayName, groupForFeedKey, groupTokens } from "./groups.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

/** Minimal chainable stub: tables → rows; filters applied in order. */
function stub(tables: Record<string, Record<string, unknown>[]>, rpcs: Record<string, unknown> = {}) {
  const from = (table: string) => {
    let rows = [...(tables[table] ?? [])];
    const q: Record<string, unknown> = {
      select: () => q,
      eq: (col: string, v: unknown) => { rows = rows.filter((r) => r[col] === v); return q; },
      in: (col: string, vs: unknown[]) => { rows = rows.filter((r) => vs.includes(r[col])); return q; },
      order: (col: string, { ascending }: { ascending: boolean }) => {
        rows.sort((a, b) => (a[col] as string) < (b[col] as string) ? (ascending ? -1 : 1) : (ascending ? 1 : -1));
        return q;
      },
      limit: (n: number) => { rows = rows.slice(0, n); return q; },
      maybeSingle: () => Promise.resolve({ data: rows[0] ?? null, error: null }),
      then: (resolve: (v: unknown) => void) => resolve({ data: rows, error: null }),
    };
    return q;
  };
  return {
    from,
    rpc: (name: string) => Promise.resolve({ data: rpcs[name] ?? null, error: null }),
  } as unknown as SupabaseClient;
}

const groups = [
  { id: "g-old", feed_token: "tok-old", created_at: "2026-07-01" },
  { id: "g-new", feed_token: "tok-new", created_at: "2026-09-01" },
];

Deno.test("groupForFeedKey: token picks its group; FEED_SECRET → founding; anything else never", async () => {
  Deno.env.set("FEED_SECRET", "legacy-feed");
  const db = stub({ groups });
  assert(await groupForFeedKey(db, "tok-new") === "g-new", "new group's token");
  assert(await groupForFeedKey(db, "tok-old") === "g-old", "old group's token");
  assert(await groupForFeedKey(db, "legacy-feed") === "g-old", "FEED_SECRET → founding group");
  assert(await groupForFeedKey(db, "some-other-secret") === null, "a non-feed secret is not a feed key");
  assert(await groupForFeedKey(db, "nope") === null, "unknown key");
  assert(await groupForFeedKey(db, null) === null, "missing key");
  assert(await groupForFeedKey(db, "") === null, "empty key");

  Deno.env.delete("FEED_SECRET");
  assert(await groupForFeedKey(db, "legacy-feed") === null, "no FEED_SECRET → the old value opens nothing");
});

Deno.test("groupTokens: every member's devices except the excluded user", async () => {
  const db = stub({
    group_members: [
      { group_id: "g", user_id: "can" }, { group_id: "g", user_id: "joyce" }, { group_id: "other", user_id: "stranger" },
    ],
    apns_tokens: [
      { token: "can-1", user_id: "can" }, { token: "can-2", user_id: "can" },
      { token: "joyce-1", user_id: "joyce" }, { token: "stranger-1", user_id: "stranger" },
    ],
  });
  const partners = await groupTokens(db, "g", "can");
  assert(JSON.stringify(partners) === JSON.stringify(["joyce-1"]), `partners: ${partners}`);
  const all = await groupTokens(db, "g");
  assert(all.length === 3 && !all.includes("stranger-1"), `all: ${all}`);
  const empty = await groupTokens(db, "g-nobody");
  assert(empty.length === 0, "unknown group → no tokens");
  const solo = await groupTokens(db, "other", "stranger");
  assert(solo.length === 0, "sole member excluded → nobody to notify");
});

Deno.test("displayName: profile name, else email local part, else Someone", async () => {
  const db = stub({ profiles: [{ user_id: "can", display_name: "Can" }, { user_id: "blank", display_name: null }] });
  assert(await displayName(db, "can") === "Can", "profile");
  assert(await displayName(db, "blank", "blank@example.com") === "blank", "empty profile → email");
  assert(await displayName(db, "unknown", "joyce.c@example.com") === "joyce.c", "no profile → email");
  assert(await displayName(db, null, null) === "Someone", "nothing known");
});
