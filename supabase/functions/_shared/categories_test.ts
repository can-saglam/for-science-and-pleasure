import { EVENT_CATEGORIES, normaliseCategory, PLACE_CATEGORIES } from "./categories.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

Deno.test("a place is never an 'exhibition' — that's the Goodwood case", () => {
  assert(normaliseCategory("place", "exhibition") === "gallery", "exhibition → gallery");
  assert(normaliseCategory("place", "Exhibition ") === "gallery", "trims and lower-cases");
});

Deno.test("words already in the right vocabulary pass through untouched", () => {
  for (const c of PLACE_CATEGORIES) assert(normaliseCategory("place", c) === c, `place ${c}`);
  for (const c of EVENT_CATEGORIES) assert(normaliseCategory("event", c) === c, `event ${c}`);
});

Deno.test("obvious cross-kind words map; unknown words fall back to other", () => {
  assert(normaliseCategory("place", "outdoors") === "park", "outdoors → park");
  assert(normaliseCategory("place", "theatre") === "venue", "theatre → venue");
  assert(normaliseCategory("event", "gallery") === "exhibition", "gallery → exhibition");
  assert(normaliseCategory("event", "restaurant") === "other", "restaurant event → other");
  assert(normaliseCategory("place", "spa") === "other", "unknown → other");
  assert(normaliseCategory("event", "rave") === "other", "unknown → other");
});

Deno.test("null and blank stay null", () => {
  assert(normaliseCategory("place", null) === null, "null");
  assert(normaliseCategory("event", undefined) === null, "undefined");
  assert(normaliseCategory("event", "   ") === null, "blank");
});

Deno.test("the two vocabularies only share 'other'", () => {
  const shared = PLACE_CATEGORIES.filter((c) => (EVENT_CATEGORIES as readonly string[]).includes(c));
  assert(shared.length === 1 && shared[0] === "other", `shared: ${shared.join(",")}`);
});
