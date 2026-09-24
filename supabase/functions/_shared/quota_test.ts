import { assertEquals } from "jsr:@std/assert@1";
import { consumeQuota, DAILY } from "./quota.ts";

/** A fake client: `usage` is today's usage_daily row, `plus` whether the
 * entitlements count comes back non-zero. Counting goes through the
 * `bump_usage` RPC, reported to `onBump`. */
function stub(
  usage: Record<string, number> | null,
  plus: boolean,
  onBump: (args: Record<string, unknown>) => void,
  bumpError: unknown = null,
) {
  return {
    from(table: string) {
      const q = {
        select() { return q; },
        eq() { return q; },
        in() { return q; },
        or() { return Promise.resolve({ count: plus ? 1 : 0 }); },
        maybeSingle() {
          return Promise.resolve({ data: table === "usage_daily" ? usage : { group_id: "g1" } });
        },
        then(resolve: (v: unknown) => void) {
          resolve({ data: [{ user_id: "u1" }, { user_id: "u2" }] });
        },
      };
      return q;
    },
    rpc(name: string, args: Record<string, unknown>) {
      if (name === "bump_usage") onBump(args);
      return Promise.resolve({ data: 1, error: bumpError });
    },
  } as never;
}

Deno.test("ten a day free, fifty with Plus", () => {
  assertEquals(DAILY.free, 10);
  assertEquals(DAILY.plus, 50);
});

Deno.test("first use of the day counts one of its kind", async () => {
  let bumped: Record<string, unknown> | undefined;
  const ok = await consumeQuota(stub(null, false, (args) => { bumped = args; }), "u1", "parse");
  assertEquals(ok, true);
  assertEquals(bumped?.p_user_id, "u1");
  assertEquals(bumped?.p_kind, "parse");
  assertEquals(typeof bumped?.p_day, "string");
});

Deno.test("kinds share one allowance", async () => {
  const bumps: unknown[] = [];
  const ok = await consumeQuota(stub({ parse: 6, locate: 1, suggest: 3 }, false, (a) => bumps.push(a)), "u1", "parse");
  assertEquals(ok, false);
  assertEquals(bumps, []);
});

Deno.test("under the free allowance counts only its own kind", async () => {
  let bumped: Record<string, unknown> | undefined;
  const ok = await consumeQuota(stub({ parse: 3, locate: 0, suggest: 1 }, false, (a) => { bumped = a; }), "u1", "suggest");
  assertEquals(ok, true);
  assertEquals(bumped?.p_kind, "suggest");
});

Deno.test("a failed count refuses rather than letting it through uncounted", async () => {
  const ok = await consumeQuota(stub(null, false, () => {}, { message: "down" }), "u1", "parse");
  assertEquals(ok, false);
});

Deno.test("Plus keeps going past ten", async () => {
  const ok = await consumeQuota(stub({ parse: 10, locate: 0, suggest: 0 }, true, () => {}), "u1", "parse");
  assertEquals(ok, true);
});

Deno.test("Plus stops at fifty", async () => {
  const ok = await consumeQuota(stub({ parse: 45, locate: 0, suggest: 5 }, true, () => {}), "u1", "parse");
  assertEquals(ok, false);
});
