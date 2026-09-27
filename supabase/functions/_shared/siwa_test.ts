import { exportPKCS8, generateKeyPair } from "npm:jose@5";
import { revokeAppleAccess } from "./siwa.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const b64url = (s: string) => btoa(s).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
const idToken = (sub: string) => `${b64url('{"alg":"none"}')}.${b64url(JSON.stringify({ sub }))}.x`;

type Call = { url: string; form: URLSearchParams };

/** Runs `fn` against a fake Apple that issues tokens for `sub`. */
async function withApple(sub: string, fn: (calls: Call[]) => Promise<void>) {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  Deno.env.set("SIWA_KEY_ID", "KEY1234567");
  Deno.env.set("SIWA_TEAM_ID", "TEAM123456");
  Deno.env.set("SIWA_PRIVATE_KEY", await exportPKCS8(privateKey));
  const calls: Call[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, form: new URLSearchParams(String(init?.body ?? "")) });
    if (url.endsWith("/auth/token")) {
      return Response.json({ refresh_token: "r-token", access_token: "a-token", id_token: idToken(sub) });
    }
    return new Response("", { status: 200 });
  }) as typeof fetch;
  try {
    await fn(calls);
  } finally {
    globalThis.fetch = real;
    for (const k of ["SIWA_KEY_ID", "SIWA_TEAM_ID", "SIWA_PRIVATE_KEY"]) Deno.env.delete(k);
  }
}

Deno.test("revocation trades the code and revokes the refresh token", async () => {
  await withApple("apple-sub-1", async (calls) => {
    const outcome = await revokeAppleAccess("the-code", "apple-sub-1");
    assert(outcome === "revoked", `got ${outcome}`);
    assert(calls.length === 2, `expected exchange + revoke, got ${calls.length}`);
    assert(calls[0].form.get("code") === "the-code", "exchange sends the code");
    assert(calls[0].form.get("client_id") === "com.cansaglam.CanWeGo", "client id is the bundle id");
    assert(calls[1].url.endsWith("/auth/revoke"), "second call revokes");
    assert(calls[1].form.get("token") === "r-token", "revokes the refresh token");
  });
});

Deno.test("a code for another Apple ID revokes nothing", async () => {
  await withApple("someone-else", async (calls) => {
    const outcome = await revokeAppleAccess("the-code", "apple-sub-1");
    assert(outcome === "wrong_account", `got ${outcome}`);
    assert(!calls.some((c) => c.url.endsWith("/auth/revoke")), "no revoke call");
  });
});

Deno.test("without the key nothing is sent", async () => {
  const outcome = await revokeAppleAccess("the-code", "apple-sub-1");
  assert(outcome === "not_configured", `got ${outcome}`);
});
