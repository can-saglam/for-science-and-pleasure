import { assert, assertEquals } from "jsr:@std/assert@1";
import { CODE_ALPHABET, formatCode, inviteMessage, isAction, normaliseCode } from "./membership.ts";

Deno.test("normaliseCode: accepts dashes, spaces and lower-case", () => {
  assertEquals(normaliseCode("kv7-p2m"), "KV7P2M");
  assertEquals(normaliseCode(" KV7 P2M "), "KV7P2M");
  assertEquals(normaliseCode("KV7P2M"), "KV7P2M");
});

Deno.test("normaliseCode: rejects ambiguous letters, wrong length, junk", () => {
  assertEquals(normaliseCode("KV7P2O"), null, "O is not in the alphabet");
  assertEquals(normaliseCode("KV7P21"), null, "1 is not in the alphabet");
  assertEquals(normaliseCode("KV7P2"), null);
  assertEquals(normaliseCode("KV7P2MM"), null);
  assertEquals(normaliseCode(""), null);
  assertEquals(normaliseCode(null), null);
  assertEquals(normaliseCode("../etc"), null);
});

Deno.test("alphabet has no 0, O, 1 or I and every letter round-trips", () => {
  for (const bad of ["0", "O", "1", "I"]) assert(!CODE_ALPHABET.includes(bad), bad);
  for (const ch of CODE_ALPHABET) assertEquals(normaliseCode(ch.repeat(6)), ch.repeat(6));
});

Deno.test("formatCode shows ABC-DEF", () => {
  assertEquals(formatCode("KV7P2M"), "KV7-P2M");
  assertEquals(formatCode("kv7p2m"), "KV7-P2M");
});

Deno.test("isAction", () => {
  assert(isAction("join"));
  assert(!isAction("drop_table"));
  assert(!isAction(42));
});

Deno.test("inviteMessage", () => {
  assertEquals(inviteMessage("KV7P2M", "Joyce", null), "Join Joyce on Can We Go? — code KV7-P2M");
  assertEquals(
    inviteMessage("KV7P2M", null, "https://apps.apple.com/x"),
    "Join me on Can We Go? — code KV7-P2M https://apps.apple.com/x",
  );
});
