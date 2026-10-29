import { assertEquals } from "jsr:@std/assert@1";
import {
  bumpVague,
  DAILY,
  releaseQuota,
  reserveQuota,
  VAGUE_STRIKES,
  vagueStrikes,
} from "./quota.ts";

/** A fake client: `usage` is today's usage_daily row, `plus` whether the
 * entitlements count comes back non-zero. `reserve_usage` behaves like the
 * SQL: it counts the kind only while the total is under the cap. Every RPC
 * is reported to `onRpc`. */
function stub(
  usage: Record<string, number> | null,
  plus: boolean,
  onRpc: (name: string, args: Record<string, unknown>) => void = () => {},
  rpcError: unknown = null,
) {
  const row: Record<string, number> = { parse: 0, locate: 0, suggest: 0, ...usage };
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
      onRpc(name, args);
      if (rpcError) return Promise.resolve({ data: null, error: rpcError });
      if (name === "reserve_usage") {
        const kind = args.p_kind as string;
        const total = row.parse + row.locate + row.suggest;
        const kindCap = args.p_kind_cap as number | null;
        const room = total < (args.p_cap as number) && (kindCap === null || row[kind] < kindCap);
        if (room) row[kind] += 1;
        return Promise.resolve({ data: room, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    },
  } as never;
}

Deno.test("twenty a day free, a hundred with Plus: twice the saves people see", () => {
  assertEquals(DAILY.free, 20);
  assertEquals(DAILY.plus, 100);
});

Deno.test("first use of the day reserves one of its kind", async () => {
  const calls: Record<string, unknown>[] = [];
  const ok = await reserveQuota(stub(null, false, (_, a) => calls.push(a)), "u1", "parse");
  assertEquals(ok, true);
  assertEquals(calls[0].p_user_id, "u1");
  assertEquals(calls[0].p_kind, "parse");
  assertEquals(calls[0].p_cap, DAILY.free);
  assertEquals(typeof calls[0].p_day, "string");
});

Deno.test("kinds share one allowance", async () => {
  assertEquals(await reserveQuota(stub({ parse: 12, locate: 2, suggest: 6 }, false), "u1", "parse"), false);
});

Deno.test("reservations sent together stop at the cap", async () => {
  const db = stub({ parse: 18 }, false);
  const results = await Promise.all(Array.from({ length: 5 }, () => reserveQuota(db, "u1", "parse")));
  assertEquals(results.filter(Boolean).length, 2);
});

Deno.test("a kind can have its own smaller cap", async () => {
  const db = stub({ suggest: 2 }, false);
  assertEquals(await reserveQuota(db, "u1", "suggest", 3), true);
  assertEquals(await reserveQuota(db, "u1", "suggest", 3), false);
  assertEquals(await reserveQuota(db, "u1", "parse", 3), true);
});

Deno.test("a failed reservation refuses rather than letting it through uncounted", async () => {
  assertEquals(await reserveQuota(stub(null, false, () => {}, { message: "down" }), "u1", "parse"), false);
});

Deno.test("Plus keeps going past twenty", async () => {
  assertEquals(await reserveQuota(stub({ parse: 20 }, true), "u1", "parse"), true);
});

Deno.test("Plus stops at a hundred", async () => {
  assertEquals(await reserveQuota(stub({ parse: 95, suggest: 5 }, true), "u1", "parse"), false);
});

Deno.test("an uncharged call gives its slot back", async () => {
  const names: string[] = [];
  await releaseQuota(stub(null, false, (n) => names.push(n)), "u1", "parse");
  assertEquals(names, ["release_usage"]);
});

Deno.test("the note gets firmer after four searches", () => {
  assertEquals(VAGUE_STRIKES, 4);
});

Deno.test("search strikes read today's row, zero without one", async () => {
  assertEquals(await vagueStrikes(stub({ vague: 3 }, false), "u1"), 3);
  assertEquals(await vagueStrikes(stub(null, false), "u1"), 0);
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
