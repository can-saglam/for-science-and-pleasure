import { cleanLink, isAnchored, linkKey } from "./extract.ts";

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

Deno.test("a saved link loses click tracking and keeps what names the page", () => {
  assert(
    cleanLink("https://www.goodwoodartfoundation.org/art/nancy-holt-2026/?_gl=1*abc&utm_source=ig") ===
      "https://www.goodwoodartfoundation.org/art/nancy-holt-2026/",
    "tracking stripped",
  );
  assert(
    cleanLink("https://mosaicrooms.org/exhibitions-2026-2?id=7#sounding-towards") ===
      "https://mosaicrooms.org/exhibitions-2026-2?id=7#sounding-towards",
    "real query and fragment kept",
  );
  assert(cleanLink("javascript:alert(1)") === null, "only web links");
  assert(cleanLink("not a url") === null, "junk");
});

Deno.test("one page compares equal however it's spelled", () => {
  assert(
    linkKey("https://www.southbankcentre.co.uk/whats-on/anish-kapoor/") ===
      linkKey("https://southbankcentre.co.uk/whats-on/anish-kapoor?utm_medium=social#top"),
    "www, slash, tracking and fragment ignored",
  );
  assert(
    linkKey("https://barbican.org.uk/whats-on/a") !== linkKey("https://barbican.org.uk/whats-on/b"),
    "different pages differ",
  );
});
