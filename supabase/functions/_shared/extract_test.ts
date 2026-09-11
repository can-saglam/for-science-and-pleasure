import { isAnchored } from "./extract.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

const none = { url: null, coords: null };
const place = { kind: "place" as const, website: null, address: null, venue: null, starts_on: null };
const event = { ...place, kind: "event" as const };

Deno.test("a place with no link, site, pin or address is a phantom", () => {
  assert(!isAnchored(place, none), "bare place passed");
  assert(!isAnchored({ ...place, venue: "Somewhere" }, none), "a venue name alone is not a location");
});

Deno.test("any real handle anchors a place", () => {
  assert(isAnchored(place, { url: "https://x.com/p", coords: null }), "source link");
  assert(isAnchored(place, { url: null, coords: { lat: 51.5, lng: -0.1 } }), "coordinates");
  assert(isAnchored({ ...place, website: "https://tate.org.uk" }, none), "official site");
  assert(isAnchored({ ...place, address: "Bankside, London SE1 9TG" }, none), "street address");
});

Deno.test("an event may stand on its venue or its date", () => {
  assert(!isAnchored(event, none), "bare event passed");
  assert(isAnchored({ ...event, venue: "Barbican" }, none), "named venue");
  assert(isAnchored({ ...event, starts_on: "2026-10-14" }, none), "dated");
});
