import { assertEquals } from "jsr:@std/assert@1";
import { CAPS, consumeQuota, type QuotaKind } from "./quota.ts";

function stub(existing: Record<string, number> | null, onWrite: (op: string, row: unknown) => void) {
  return {
    from() {
      const q = {
        select() { return q; },
        eq() { return q; },
        update(row: unknown) {
          onWrite("update", row);
          return { eq() { return q; } };
        },
        insert(row: unknown) {
          onWrite("insert", row);
          return Promise.resolve({ error: null });
        },
        maybeSingle() {
          return Promise.resolve({ data: existing });
        },
      };
      return q;
    },
  } as never;
}

Deno.test("caps stay in the tens for parse/locate and a handful for suggest", () => {
  assertEquals(CAPS.parse, 40);
  assertEquals(CAPS.locate, 40);
  assertEquals(CAPS.suggest, 8);
});

Deno.test("consumeQuota inserts the first use of the day", async () => {
  let wrote: unknown;
  const ok = await consumeQuota(stub(null, (_op, row) => { wrote = row; }), "u1", "parse");
  assertEquals(ok, true);
  assertEquals((wrote as { parse: number }).parse, 1);
});

Deno.test("consumeQuota refuses when the cap is already hit", async () => {
  const writes: string[] = [];
  const ok = await consumeQuota(
    stub({ parse: 40, locate: 0, suggest: 0 }, (op) => writes.push(op)),
    "u1",
    "parse",
  );
  assertEquals(ok, false);
  assertEquals(writes, []);
});

Deno.test("consumeQuota increments a kind under the cap", async () => {
  let wrote: unknown;
  const ok = await consumeQuota(
    stub({ parse: 3, locate: 0, suggest: 0 }, (_op, row) => { wrote = row; }),
    "u1",
    "parse" as QuotaKind,
  );
  assertEquals(ok, true);
  assertEquals((wrote as { parse: number }).parse, 4);
});
