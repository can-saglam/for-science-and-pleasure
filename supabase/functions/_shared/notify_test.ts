import { assertEquals } from "jsr:@std/assert@1";
import { memberLine } from "./notify.ts";

Deno.test("memberLine: someone joins", () => {
  assertEquals(memberLine("Joyce", "joined"), "Joyce joined your group");
  assertEquals(
    memberLine("Joyce", "joined", true),
    "Joyce joined your group. Their saves are in the library now.",
  );
});

Deno.test("memberLine: someone leaves", () => {
  assertEquals(memberLine("Joyce", "left"), "Joyce left your group. Everything saved stays here.");
});
