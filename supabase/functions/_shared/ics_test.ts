import { assertEquals } from "jsr:@std/assert@1";
import { icsFold, icsLink, icsStamp, icsText } from "./ics.ts";

Deno.test("icsText escapes separators and every kind of line break", () => {
  assertEquals(icsText("a,b;c\\d"), "a\\,b\\;c\\\\d");
  assertEquals(icsText("one\r\ntwo\rthree\nfour"), "one\\ntwo\\nthree\\nfour");
});

Deno.test("icsLink keeps web links only", () => {
  assertEquals(icsLink("https://example.com/a b"), "https://example.com/a%20b");
  assertEquals(icsLink("javascript:alert(1)"), null);
  assertEquals(icsLink("https://example.com/\r\nX-EVIL:1"), null);
  assertEquals(icsLink(null), null);
});

Deno.test("icsStamp is UTC without separators", () => {
  assertEquals(icsStamp(new Date("2026-11-20T15:15:00.123Z")), "20261120T151500Z");
});

Deno.test("icsFold keeps every line within 75 octets, multibyte included", () => {
  const folded = icsFold(`SUMMARY:${"Ağ".repeat(60)}`);
  for (const line of folded.split("\r\n")) {
    if (new TextEncoder().encode(line).length > 75) throw new Error(`too long: ${line}`);
  }
  assertEquals(folded.split("\r\n").map((l, i) => (i ? l.slice(1) : l)).join(""), `SUMMARY:${"Ağ".repeat(60)}`);
});
