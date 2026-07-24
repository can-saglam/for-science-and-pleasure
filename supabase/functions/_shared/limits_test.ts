import { assertImageWithinLimit, base64DecodedBytes, MAX_IMAGE_BYTES } from "./limits.ts";

Deno.test("base64DecodedBytes accounts for padding", () => {
  // "AAAA" decodes to 3 bytes
  if (base64DecodedBytes("AAAA") !== 3) {
    throw new Error(`expected 3, got ${base64DecodedBytes("AAAA")}`);
  }
  if (base64DecodedBytes("AAA=") !== 2) {
    throw new Error(`expected 2, got ${base64DecodedBytes("AAA=")}`);
  }
  if (base64DecodedBytes("AA==") !== 1) {
    throw new Error(`expected 1, got ${base64DecodedBytes("AA==")}`);
  }
});

Deno.test("assertImageWithinLimit allows small payloads", () => {
  assertImageWithinLimit("AAAA");
});

Deno.test("assertImageWithinLimit rejects oversized payloads", () => {
  const oversized = "A".repeat(Math.ceil((MAX_IMAGE_BYTES + 16) * 4 / 3));
  let threw = false;
  try {
    assertImageWithinLimit(oversized);
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("expected size limit error");
});
