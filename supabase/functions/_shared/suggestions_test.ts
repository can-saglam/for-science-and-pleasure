import { assert, assertEquals } from "jsr:@std/assert";
import { aboutEvent, answerText, isDue, leaseFree, readItems, servePool, shapeSuggestions, stillOn } from "./suggestions.ts";

Deno.test("a listing that mentions the event isn't its page", () => {
  const listing = (t: string) => `<html><head><title>${t}</title></head><body><h1>${t}</h1><p>An Oak Tree, Darbar Festival, Pitchfork</p></body></html>`;
  assert(!aboutEvent("An Oak Tree", listing("What's on at Harold Pinter Theatre | ATG Tickets"), "https://www.atgtickets.com/venues/harold-pinter-theatre/whats-on/"));
  assert(!aboutEvent("Darbar Festival", listing("London events in November 2026 - London Cheapo"), "https://londoncheapo.com/events/november/"));
  assert(!aboutEvent("Pitchfork Music Festival London", listing("Events in London in November"), "https://londontravelplanning.com/events-in-london-in-november/"));
});

Deno.test("the event's own page is", () => {
  assert(aboutEvent("Amar Kanwar", "<title>Amar Kanwar: The Sovereign Forest | Serpentine</title>", "https://www.serpentinegalleries.org/whats-on/amar-kanwar/"));
  assert(aboutEvent("Darbar Festival", '<meta property="og:title" content="Darbar Festival 2026 | Barbican">', "https://www.barbican.org.uk/whats-on/2026/series/darbar"));
  assert(aboutEvent("Poliça", "<title>Polica at EartH</title>", "https://earthackney.co.uk/events/x"));
  // Walled-off site, no html: the link has to name it.
  assert(aboutEvent("Frieze London", null, "https://www.frieze.com/fairs/frieze-london"));
  assert(!aboutEvent("Frieze London", null, "https://www.frieze.com/"));
});

Deno.test("an answer split by citations after the searches reads whole", () => {
  const content = [
    { type: "text", text: "Let me look." },
    { type: "server_tool_use" },
    { type: "web_search_tool_result" },
    { type: "text", text: '{"items": [{"title": "A", ' },
    { type: "text", text: '"url": "https://a.org/"}]}' },
  ];
  assertEquals(readItems(answerText(content))?.length, 1);
  assertEquals(readItems("not json"), null);
  assertEquals(readItems('Here: {"items": []} done')?.length, 0);
});

const today = "2026-09-26";

Deno.test("events need a date and must still be on", () => {
  const got = shapeSuggestions({
    items: [
      { title: "Amar Kanwar", venue: "Serpentine", starts_on: "2026-09-10", ends_on: "2026-11-02", url: "https://www.serpentinegalleries.org/whats-on/amar-kanwar/" },
      { title: "Ended show", venue: "Tate", starts_on: "2026-06-01", ends_on: "2026-09-20", url: "https://www.tate.org.uk/whats-on/ended" },
      { title: "Tonight", venue: "Cafe OTO", starts_on: "2026-09-26", ends_on: null, url: "https://www.cafeoto.co.uk/events/tonight/" },
      { title: "No date", venue: null, starts_on: "soon", ends_on: null, url: "https://example.org/no-date" },
    ],
  }, "event", today);
  assertEquals(got.map((s) => s.title), ["Amar Kanwar", "Tonight"]);
  assertEquals(got[0].kind, "event");
});

Deno.test("listings sites and duplicates are dropped", () => {
  const got = shapeSuggestions({
    items: [
      { title: "Gig", starts_on: "2026-10-01", ends_on: null, url: "https://dice.fm/event/abc" },
      { title: "Show A", starts_on: "2026-10-01", ends_on: null, url: "https://www.barbican.org.uk/a" },
      { title: "Show A again", starts_on: "2026-10-01", ends_on: null, url: "https://barbican.org.uk/a/" },
      { title: "Show B", starts_on: "2026-10-02", ends_on: null, url: "https://www.barbican.org.uk/b?utm_source=x" },
    ],
  }, "event", today);
  assertEquals(got.map((s) => s.title), ["Show A", "Show B"]);
  assertEquals(got[1].url, "https://www.barbican.org.uk/b");
});

Deno.test("places are one per site and never dated", () => {
  const got = shapeSuggestions({
    items: [
      { title: "Dishoom", venue: "Shoreditch", url: "https://www.dishoom.com/shoreditch/", starts_on: "2026-01-01" },
      { title: "Dishoom KX", venue: "King's Cross", url: "https://dishoom.com/kings-cross/" },
      { title: "Prince Charles Cinema", venue: "Soho", url: "http://princecharlescinema.com/" },
    ],
  }, "place", today);
  assertEquals(got.map((s) => s.title), ["Dishoom", "Prince Charles Cinema"]);
  assertEquals(got[0].starts_on, null);
  assert(got[1].url.startsWith("https://"));
});

Deno.test("an end date before the start is ignored", () => {
  const [s] = shapeSuggestions({
    items: [{ title: "Run", starts_on: "2026-10-05", ends_on: "2026-10-01", url: "https://example.org/run" }],
  }, "event", today);
  assertEquals(s.ends_on, null);
});

Deno.test("the pool is served without what's ended since", () => {
  const payload = {
    items: [
      { title: "Still on", kind: "event", url: "https://a.org/1", venue: null, starts_on: "2026-09-01", ends_on: "2026-10-01" },
      { title: "Over", kind: "event", url: "https://a.org/2", venue: null, starts_on: "2026-09-01", ends_on: "2026-09-25" },
      { title: "Place", kind: "place", url: "https://b.org/", venue: null, starts_on: null, ends_on: null },
    ],
  };
  assertEquals(servePool(payload, "event", today).map((s) => s.title), ["Still on"]);
  assertEquals(servePool(payload, "place", today).map((s) => s.title), ["Place"]);
  assertEquals(servePool(null, "event", today), []);
});

Deno.test("a one-night event is on through its day", () => {
  const s = { title: "t", url: "u", kind: "event" as const, venue: null, starts_on: today, ends_on: null };
  assert(stillOn(s, today));
  assert(!stillOn(s, "2026-09-27"));
});

Deno.test("refresh timing: weekly events, fortnightly places, sooner when thin", () => {
  const now = new Date("2026-09-26T12:00:00Z");
  assert(isDue(null, "event", 8, now));
  assert(!isDue("2026-09-22T12:00:00Z", "event", 8, now));
  assert(isDue("2026-09-19T12:00:00Z", "event", 8, now));
  assert(!isDue("2026-09-19T12:00:00Z", "place", 8, now));
  assert(isDue("2026-09-12T12:00:00Z", "place", 8, now));
  assert(isDue("2026-09-24T12:00:00Z", "event", 2, now));
  assert(!isDue("2026-09-26T06:00:00Z", "event", 2, now));
});

Deno.test("a stuck refresh frees up after five minutes", () => {
  const now = new Date("2026-09-26T12:00:00Z");
  assert(leaseFree(null, now));
  assert(!leaseFree("2026-09-26T11:58:00Z", now));
  assert(leaseFree("2026-09-26T11:50:00Z", now));
});
