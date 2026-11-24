// Entitlement states against stubbed App Store Server API replies: what a
// subscriber gets for each status Apple can report.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { exportPKCS8, generateKeyPair } from "npm:jose@5.10.0";
import { BUNDLE_ID, entitlementRow, subscriptionStatus } from "./appstore.ts";

const { privateKey } = await generateKeyPair("ES256", { extractable: true });
Deno.env.set("ASC_ISSUER_ID", "issuer");
Deno.env.set("ASC_KEY_ID", "KEY1234567");
Deno.env.set("ASC_PRIVATE_KEY", await exportPKCS8(privateKey));

const MONTHLY = "com.cansaglam.CanWeGo.plus.monthly";
const DAY = 86_400_000;
const now = Date.now();

function jws(payload: Record<string, unknown>): string {
  const part = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `${part({ alg: "ES256" })}.${part(payload)}.sig`;
}

type Last = { status: number; txn: Record<string, unknown>; renewal?: Record<string, unknown> };

function reply(last: Last[], bundleId = BUNDLE_ID): Response {
  return Response.json({
    bundleId,
    data: [{
      lastTransactions: last.map((t) => ({
        status: t.status,
        signedTransactionInfo: jws({
          originalTransactionId: "1000",
          productId: MONTHLY,
          bundleId: BUNDLE_ID,
          ...t.txn,
        }),
        signedRenewalInfo: t.renewal ? jws(t.renewal) : undefined,
      })),
    }],
  });
}

/** Answers per environment; records which were asked. */
async function withApple(
  answers: { Production?: () => Response; Sandbox?: () => Response },
  run: () => Promise<void>,
): Promise<string[]> {
  const asked: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = String(input instanceof Request ? input.url : input);
    const env = url.includes("sandbox") ? "Sandbox" : "Production";
    asked.push(env);
    const answer = answers[env];
    return Promise.resolve(answer ? answer() : new Response("", { status: 404 }));
  }) as typeof fetch;
  try {
    await run();
  } finally {
    globalThis.fetch = real;
  }
  return asked;
}

Deno.test("an active subscription runs to its paid date", async () => {
  await withApple({ Production: () => reply([{ status: 1, txn: { expiresDate: now + 20 * DAY } }]) }, async () => {
    const sub = await subscriptionStatus("1000");
    assertEquals(sub?.environment, "Production");
    assertEquals(sub?.status, 1);
    assertEquals(sub?.expiresAt?.getTime(), now + 20 * DAY);
    assertEquals(sub?.revoked, false);
    const row = entitlementRow("u1", sub!);
    assertEquals(row.expires_at, new Date(now + 20 * DAY).toISOString());
    assertEquals(row.revoked_at, null);
  });
});

Deno.test("before release, production's 401 falls through to the sandbox", async () => {
  const asked = await withApple({
    Production: () => new Response("", { status: 401 }),
    Sandbox: () => reply([{ status: 1, txn: { expiresDate: now + DAY } }]),
  }, async () => {
    assertEquals((await subscriptionStatus("1000"))?.environment, "Sandbox");
  });
  assertEquals(asked, ["Production", "Sandbox"]);
});

Deno.test("a transaction neither environment knows is no subscription", async () => {
  await withApple({}, async () => {
    assertEquals(await subscriptionStatus("1000"), null);
  });
});

Deno.test("an expired subscription ends at its paid date", async () => {
  await withApple({ Production: () => reply([{ status: 2, txn: { expiresDate: now - 3 * DAY } }]) }, async () => {
    const sub = await subscriptionStatus("1000");
    assertEquals(sub?.status, 2);
    assert(new Date(entitlementRow("u1", sub!).expires_at).getTime() < now);
  });
});

Deno.test("billing retry without grace keeps only the paid period", async () => {
  await withApple({
    Production: () =>
      reply([{
        status: 3,
        txn: { expiresDate: now - DAY },
        renewal: { gracePeriodExpiresDate: now + 5 * DAY },
      }]),
  }, async () => {
    assertEquals((await subscriptionStatus("1000"))?.expiresAt?.getTime(), now - DAY);
  });
});

Deno.test("a grace period extends access to its end", async () => {
  await withApple({
    Production: () =>
      reply([{
        status: 4,
        txn: { expiresDate: now - DAY },
        renewal: { gracePeriodExpiresDate: now + 5 * DAY },
      }]),
  }, async () => {
    assertEquals((await subscriptionStatus("1000"))?.expiresAt?.getTime(), now + 5 * DAY);
  });
});

Deno.test("a revoked subscription ends now, whatever its paid date", async () => {
  for (const last of [
    { status: 5, txn: { expiresDate: now + 20 * DAY } },
    { status: 1, txn: { expiresDate: now + 20 * DAY, revocationDate: now - DAY } },
  ]) {
    await withApple({ Production: () => reply([last]) }, async () => {
      const sub = await subscriptionStatus("1000");
      assertEquals(sub?.revoked, true);
      const row = entitlementRow("u1", sub!);
      assert(new Date(row.expires_at).getTime() <= Date.now());
      assert(row.revoked_at);
    });
  }
});

Deno.test("another app's subscription, or another product, isn't Plus", async () => {
  await withApple({ Production: () => reply([{ status: 1, txn: { expiresDate: now + DAY } }], "com.other.App") }, async () => {
    assertEquals(await subscriptionStatus("1000"), null);
  });
  await withApple({
    Production: () => reply([{ status: 1, txn: { expiresDate: now + DAY, productId: "com.cansaglam.CanWeGo.tip" } }]),
  }, async () => {
    assertEquals(await subscriptionStatus("1000"), null);
  });
});

Deno.test("of several, the one that runs latest counts", async () => {
  await withApple({
    Production: () =>
      reply([
        { status: 2, txn: { expiresDate: now - 30 * DAY, originalTransactionId: "old" } },
        { status: 1, txn: { expiresDate: now + 300 * DAY, originalTransactionId: "yearly" } },
      ]),
  }, async () => {
    const sub = await subscriptionStatus("1000");
    assertEquals(sub?.originalTransactionId, "yearly");
    assertEquals(sub?.status, 1);
  });
});

Deno.test("the account the app attached is read lowercased", async () => {
  await withApple({
    Production: () => reply([{ status: 1, txn: { expiresDate: now + DAY, appAccountToken: "8A19B3DC-AAAA" } }]),
  }, async () => {
    assertEquals((await subscriptionStatus("1000"))?.appAccountToken, "8a19b3dc-aaaa");
  });
});

Deno.test("Apple failing is an error, not a lapse", async () => {
  await withApple({ Production: () => new Response("down", { status: 500 }) }, async () => {
    await assertRejects(() => subscriptionStatus("1000"));
  });
});
