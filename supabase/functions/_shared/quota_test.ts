import { assertEquals } from "jsr:@std/assert@1";
import {
  bumpVague,
  chargeQuota,
  consumeQuota,
  DAILY,
  hasQuota,
  VAGUE_STRIKES,
  vagueStrikes,
} from "./quota.ts";

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

Deno.test("twenty a day free, a hundred with Plus: twice the saves people see", () => {
  assertEquals(DAILY.free, 20);
  assertEquals(DAILY.plus, 100);
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
  const ok = await consumeQuota(stub({ parse: 12, locate: 2, suggest: 6 }, false, (a) => bumps.push(a)), "u1", "parse");
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

Deno.test("Plus keeps going past twenty", async () => {
  const ok = await consumeQuota(stub({ parse: 20, locate: 0, suggest: 0 }, true, () => {}), "u1", "parse");
  assertEquals(ok, true);
});

Deno.test("Plus stops at a hundred", async () => {
  const ok = await consumeQuota(stub({ parse: 95, locate: 0, suggest: 5 }, true, () => {}), "u1", "parse");
  assertEquals(ok, false);
});

Deno.test("checking the allowance counts nothing; charging counts one", async () => {
  const bumps: Record<string, unknown>[] = [];
  const db = stub({ parse: 3, locate: 0, suggest: 0 }, false, (a) => bumps.push(a));
  assertEquals(await hasQuota(db, "u1"), true);
  assertEquals(bumps, []);
  assertEquals(await chargeQuota(db, "u1", "parse"), true);
  assertEquals(bumps.map((b) => b.p_kind), ["parse"]);
});

Deno.test("a spent allowance says so before anything is asked", async () => {
  assertEquals(await hasQuota(stub({ parse: 20, locate: 0, suggest: 0 }, false, () => {}), "u1"), false);
  assertEquals(await hasQuota(stub({ parse: 20, locate: 0, suggest: 0 }, true, () => {}), "u1"), true);
});

Deno.test("the note gets firmer after four searches", () => {
  assertEquals(VAGUE_STRIKES, 4);
});

Deno.test("search strikes read today's row, zero without one", async () => {
  assertEquals(await vagueStrikes(stub({ vague: 3 }, false, () => {}), "u1"), 3);
  assertEquals(await vagueStrikes(stub(null, false, () => {}), "u1"), 0);
});

Deno.test("a strike is counted through bump_vague and returns today's total", async () => {
  let called = "";
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      called = `${name}:${args.p_user_id}`;
      return Promise.resolve({ data: 5, error: null });
    },
  } as never;
  assertEquals(await bumpVague(db, "u1"), 5);
  assertEquals(called, "bump_vague:u1");
});
