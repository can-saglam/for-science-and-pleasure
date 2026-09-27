import { sameSecret } from "./auth.ts";

Deno.test("secrets match only exactly", () => {
  const cases: [string | null | undefined, string | null | undefined, boolean][] = [
    ["abc123", "abc123", true],
    ["abc124", "abc123", false],
    ["abc12", "abc123", false],
    ["abc1234", "abc123", false],
    ["abcabc", "abc", false],
    ["", "abc", false],
    ["abc", "", false],
    [null, "abc", false],
    ["abc", undefined, false],
    ["café", "café", true],
    ["cafe", "café", false],
  ];
  for (const [given, expected, want] of cases) {
    if (sameSecret(given, expected) !== want) {
      throw new Error(`sameSecret(${given}, ${expected}) should be ${want}`);
    }
  }
});
