import { assertEquals } from "jsr:@std/assert";
import { shapeStarters, starterFresh, starterKey } from "./starters.ts";

Deno.test("starter key folds case and whitespace", () => {
  assertEquals(starterKey(" Lisbon ", "Portugal"), "lisbon|portugal");
  assertEquals(starterKey("New  York", "United States"), "new york|united states");
});

Deno.test("starter freshness is the TTL", () => {
  const now = new Date("2026-09-18T12:00:00Z");
  assertEquals(starterFresh("2026-09-10T12:00:00Z", now), true);
  assertEquals(starterFresh("2026-09-01T12:00:00Z", now), false);
});

Deno.test("shape: https only, aggregators and duplicates dropped, capped at three", () => {
  const shaped = shapeStarters({
    starters: [
      { title: "Tate Modern", url: "http://www.tate.org.uk/visit/tate-modern", kind: "place" },
      { title: "Best restaurants in London", url: "https://www.timeout.com/london/restaurants", kind: "place" },
      { title: "Tate Britain", url: "https://www.tate.org.uk/visit/tate-britain", kind: "place" },
      { title: "Frieze London", url: "https://www.frieze.com/fairs/frieze-london", kind: "event" },
      { title: "", url: "https://example.org", kind: "place" },
      { title: "Sessions Arts Club", url: "https://sessionsartsclub.com", kind: "cafe" },
      { title: "Roundhouse", url: "https://www.roundhouse.org.uk", kind: "place" },
    ],
  });
  assertEquals(shaped, [
    { title: "Tate Modern", url: "https://www.tate.org.uk/visit/tate-modern", kind: "place" },
    { title: "Frieze London", url: "https://www.frieze.com/fairs/frieze-london", kind: "event" },
    { title: "Sessions Arts Club", url: "https://sessionsartsclub.com/", kind: "place" },
  ]);
});

Deno.test("shape: garbage in, empty out", () => {
  assertEquals(shapeStarters(null), []);
  assertEquals(shapeStarters({ starters: "nope" }), []);
  assertEquals(shapeStarters({ starters: [{ title: "x", url: "not a url" }] }), []);
});
