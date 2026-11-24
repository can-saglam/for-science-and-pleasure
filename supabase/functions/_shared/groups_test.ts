// Group helpers against a stub Supabase client: the fallbacks and the
// exclusion logic are what a wrong line would silently break.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { displayName, groupForFeedKey, groupTokens, steadyFetch } from "./groups.ts";

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

Deno.test("groupForFeedKey: a token picks its group; anything else never", async () => {
  Deno.env.set("FEED_SECRET", "legacy-feed");
  const db = stub({ groups });
  assert(await groupForFeedKey(db, "tok-new") === "g-new", "new group's token");
  assert(await groupForFeedKey(db, "tok-old") === "g-old", "old group's token");
  assert(await groupForFeedKey(db, "legacy-feed") === null, "the retired shared secret opens nothing");
  assert(await groupForFeedKey(db, "nope") === null, "unknown key");
  assert(await groupForFeedKey(db, null) === null, "missing key");
  assert(await groupForFeedKey(db, "") === null, "empty key");
  Deno.env.delete("FEED_SECRET");
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

/** Answers in turn, counting the calls. */
async function withAnswers(answers: [number, string][], run: (calls: () => number) => Promise<void>) {
  const real = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (() => {
    const [status, body] = answers[Math.min(calls++, answers.length - 1)];
    return Promise.resolve(new Response(body, { status }));
  }) as typeof fetch;
  try {
    await run(() => calls);
  } finally {
    globalThis.fetch = real;
  }
}

Deno.test("a token stamped ahead of the database's clock is retried", async () => {
  await withAnswers([[401, '{"message":"JWT issued at future"}'], [200, "[]"]], async (calls) => {
    const res = await steadyFetch("https://db.example/rest/v1/x");
    assert(res.status === 200 && calls() === 2, `status ${res.status}, calls ${calls()}`);
  });
});

Deno.test("any other refusal comes straight back", async () => {
  await withAnswers([[401, '{"message":"JWT expired"}'], [200, "[]"]], async (calls) => {
    const res = await steadyFetch("https://db.example/rest/v1/x");
    assert(res.status === 401 && calls() === 1, `status ${res.status}, calls ${calls()}`);
  });
});
