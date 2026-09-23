import { assertEquals } from "jsr:@std/assert@1";
import { consumeQuota, DAILY } from "./quota.ts";

/** A fake client: `usage` is today's usage_daily row, `plus` whether the
 * entitlements count comes back non-zero. */
function stub(usage: Record<string, number> | null, plus: boolean, onWrite: (op: string, row: unknown) => void) {
  return {
    from(table: string) {
      const q = {
        select() { return q; },
        eq() { return q; },
        in() { return q; },
        or() { return Promise.resolve({ count: plus ? 1 : 0 }); },
        update(row: unknown) {
          onWrite("update", row);
          return { eq() { return q; } };
        },
        insert(row: unknown) {
          onWrite("insert", row);
          return Promise.resolve({ error: null });
        },
        maybeSingle() {
          return Promise.resolve({ data: table === "usage_daily" ? usage : { group_id: "g1" } });
        },
        then(resolve: (v: unknown) => void) {
          resolve({ data: [{ user_id: "u1" }, { user_id: "u2" }] });
        },
      };
      return q;
    },
  } as never;
}

Deno.test("ten a day free, fifty with Plus", () => {
  assertEquals(DAILY.free, 10);
  assertEquals(DAILY.plus, 50);
});

Deno.test("first use of the day inserts a row", async () => {
  let wrote: unknown;
  const ok = await consumeQuota(stub(null, false, (_op, row) => { wrote = row; }), "u1", "parse");
  assertEquals(ok, true);
  assertEquals((wrote as { parse: number }).parse, 1);
});

Deno.test("kinds share one allowance", async () => {
  const writes: string[] = [];
  const ok = await consumeQuota(stub({ parse: 6, locate: 1, suggest: 3 }, false, (op) => writes.push(op)), "u1", "parse");
  assertEquals(ok, false);
  assertEquals(writes, []);
});

Deno.test("under the free allowance increments only its own kind", async () => {
  let wrote: unknown;
  const ok = await consumeQuota(stub({ parse: 3, locate: 0, suggest: 1 }, false, (_op, row) => { wrote = row; }), "u1", "suggest");
  assertEquals(ok, true);
  assertEquals(wrote, { suggest: 2 });
});

Deno.test("Plus keeps going past ten", async () => {
  const ok = await consumeQuota(stub({ parse: 10, locate: 0, suggest: 0 }, true, () => {}), "u1", "parse");
  assertEquals(ok, true);
});

Deno.test("Plus stops at fifty", async () => {
  const ok = await consumeQuota(stub({ parse: 45, locate: 0, suggest: 5 }, true, () => {}), "u1", "parse");
  assertEquals(ok, false);
});
