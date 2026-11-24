import { assert, assertEquals, assertRejects } from "jsr:@std/assert";
import {
  BlockedAddress,
  isPrivateIp,
  isPublicUrl,
  publicFetch,
  readCapped,
  readTextCapped,
  type Resolver,
  resolvesPublic,
} from "./netguard.ts";

Deno.test("private and special addresses are recognised", () => {
  for (const ip of [
    "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
    "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "::", "fe80::1", "fd00::1", "fc12::3",
    "::ffff:127.0.0.1", "::ffff:7f00:1", "::ffff:a9fe:a9fe", "[::1]", "not-an-ip",
  ]) {
    assert(isPrivateIp(ip), ip);
  }
  for (const ip of ["8.8.8.8", "1.1.1.1", "172.32.0.1", "2606:4700::1111", "::ffff:8.8.8.8", "151.101.1.69"]) {
    assert(!isPrivateIp(ip), ip);
  }
});

Deno.test("URLs that could only be local are refused before any lookup", () => {
  for (const url of [
    "http://localhost/", "http://127.0.0.1/", "http://2130706433/", "http://0x7f.1/", "http://127.1/",
    "http://[::1]/", "http://169.254.169.254/latest/meta-data/", "http://kong:8000/", "http://db/",
    "http://printer.local/", "http://metadata.google.internal/", "file:///etc/passwd",
    "ftp://example.com/", "https://example.com:8443/", "https://user:pass@example.com/",
  ]) {
    assert(!isPublicUrl(url), url);
  }
  for (const url of ["https://www.tate.org.uk/whats-on", "http://example.com:80/", "https://example.com:443/x"]) {
    assert(isPublicUrl(url), url);
  }
});

const online = (await Deno.permissions.query({ name: "net" })).state === "granted";

Deno.test({ name: "a public name that resolves to a private address is refused", ignore: !online }, async () => {
  // localtest.me and its subdomains resolve to 127.0.0.1 by design.
  assertEquals(await resolvesPublic("http://localtest.me/"), false);
  assertEquals(await resolvesPublic("https://example.com/"), true);
});

/// Stand-in DNS: per record type, addresses or an error to throw.
const fakeDns = (answers: Partial<Record<"A" | "AAAA", string[] | Error>>): Resolver => (_host, type) => {
  const answer = answers[type] ?? new Deno.errors.NotFound("no records");
  return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
};

Deno.test("a name that can't be looked up is refused", async () => {
  const timeout = new Error("timed out");
  assertEquals(await resolvesPublic("https://example.com/", fakeDns({ A: timeout, AAAA: timeout })), false);
  assertEquals(await resolvesPublic("https://example.com/", fakeDns({ A: timeout })), false);
  assertEquals(await resolvesPublic("https://example.com/", fakeDns({})), false);
});

Deno.test("one family answering is enough, unless it names a private address", async () => {
  const timeout = new Error("timed out");
  assertEquals(await resolvesPublic("https://example.com/", fakeDns({ A: ["93.184.215.14"], AAAA: timeout })), true);
  assertEquals(await resolvesPublic("https://example.com/", fakeDns({ A: ["93.184.215.14"], AAAA: ["::1"] })), false);
  assertEquals(await resolvesPublic("https://example.com/", fakeDns({ A: ["127.0.0.1"], AAAA: timeout })), false);
});

Deno.test("a runtime without DNS falls back to the hostname checks", async () => {
  const none = new Deno.errors.NotSupported("no dns");
  assertEquals(await resolvesPublic("https://example.com/", fakeDns({ A: none, AAAA: none })), true);
  assertEquals(await resolvesPublic("http://localhost/", fakeDns({ A: none, AAAA: none })), false);
});

/// A body arriving in `chunks` pieces of `size` bytes, counting how many
/// were pulled.
function streamed(chunks: number, size: number, headers: HeadersInit = {}) {
  let pulled = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (pulled === chunks) return controller.close();
      pulled++;
      controller.enqueue(new Uint8Array(size).fill(65));
    },
  });
  return { res: new Response(body, { headers }), pulled: () => pulled };
}

Deno.test("a capped read stops downloading at the limit", async () => {
  const { res, pulled } = streamed(100, 1000);
  const bytes = await readCapped(res, 2500);
  assertEquals(bytes?.length, 2500);
  assert(pulled() <= 4, `pulled ${pulled()} chunks`);
});

Deno.test("a whole read refuses what's too big, by header or by bytes", async () => {
  const declared = streamed(1, 10, { "content-length": "9000000" });
  assertEquals(await readCapped(declared.res, 8_000_000, true), null);
  assertEquals(declared.pulled(), 0);
  assertEquals(await readCapped(streamed(5, 1000).res, 4000, true), null);
  assertEquals((await readCapped(streamed(4, 1000).res, 4000, true))?.length, 4000);
});

Deno.test("capped text reads what's there", async () => {
  assertEquals(await readTextCapped(new Response("hello"), 100), "hello");
  assertEquals(await readTextCapped(new Response("hello"), 3), "hel");
});

/// Stand-in network: each URL answers with a redirect or a page.
async function withFakeNet(routes: Record<string, string | null>, run: (asked: string[]) => Promise<void>) {
  const real = globalThis.fetch;
  const asked: string[] = [];
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = String(input instanceof Request ? input.url : input);
    asked.push(url);
    const to = routes[url];
    return Promise.resolve(
      to ? new Response(null, { status: 302, headers: { location: to } }) : new Response("page"),
    );
  }) as typeof fetch;
  try {
    await run(asked);
  } finally {
    globalThis.fetch = real;
  }
}

Deno.test({ name: "a redirect into the private network is stopped before it's fetched", sanitizeResources: false }, async () => {
  await withFakeNet({
    "https://example.com/go": "http://169.254.169.254/latest/meta-data/",
  }, async (asked) => {
    await assertRejects(() => publicFetch("https://example.com/go"), BlockedAddress);
    assertEquals(asked, ["https://example.com/go"]);
  });
  await assertRejects(() => publicFetch("http://127.0.0.1:8080/"), BlockedAddress);
});

Deno.test({ name: "an ordinary redirect is followed and reports where it landed", sanitizeResources: false }, async () => {
  await withFakeNet({
    "http://example.com/a": "/b",
    "http://example.com/b": "https://example.org/c",
  }, async (asked) => {
    const res = await publicFetch("http://example.com/a");
    assertEquals(await res.text(), "page");
    assertEquals(res.url, "https://example.org/c");
    assertEquals(asked.length, 3);
  });
});

Deno.test({ name: "manual redirects hand the 3xx back unfollowed", sanitizeResources: false }, async () => {
  await withFakeNet({ "https://example.com/s": "https://example.org/long" }, async () => {
    const res = await publicFetch("https://example.com/s", { redirect: "manual" });
    assertEquals(res.status, 302);
    assertEquals(res.headers.get("location"), "https://example.org/long");
  });
});
