import { cleanLink, isAnchored, isThisRun, linkKey, mentionsDate } from "./extract.ts";

Deno.test("another year's page at the same address isn't this run", () => {
  const nov13 = ["2026-11-13"];
  assert(!isThisRun(`<p>13-22 November</p><p>Thu 19 November 2020</p><footer>© 2026</footer>`, nov13), "2020 gig");
  assert(isThisRun(`<p>Fri 13 November 2026</p>`, nov13), "this year's");
  // The model's end date was 17 Jan; the page says 3 Jan. Still this run.
  assert(isThisRun(`<span>Until 3 Jan 2027</span>`, ["2026-07-09", "2027-01-17"]), "dates a little off");
  assert(isThisRun(`<div id="app"></div><footer>© 2026</footer>`, nov13), "no dates to judge by");
  assert(isThisRun(`<p>19 November 2020</p>`, []), "places have no dates");
  assert(!isThisRun(`<p>March 3rd, 2024</p>`, ["2026-03-03"]), "month-first, old year");
});

Deno.test("an event's page has to name its date", () => {
  const page = (body: string) => `<html><body><footer>© 2026</footer>${body}</body></html>`;
  assert(mentionsDate(page("<h2>Fri 13 November 2026</h2>"), "2026-11-13"), "13 November");
  assert(mentionsDate(page("Nov 13th, doors 7pm"), "2026-11-13"), "Nov 13th");
  assert(mentionsDate(page("<p>13/11/2026</p>"), "2026-11-13"), "numeric");
  assert(mentionsDate(`<script type="application/ld+json">{"startDate":"2026-11-13T19:30"}</script>`, "2026-11-13"), "JSON-LD");
  assert(mentionsDate(page("16 Jun – 18 Oct 2026"), "2026-06-16"), "exhibition run");
  assert(mentionsDate(page("Sat 26 Sept"), "2026-09-26"), "Sept");
  // The same address's 2020 gig, and a different day that month.
  assert(!mentionsDate(`<p>13-22 November</p><p>Thu 19 November 2020</p>`, "2026-11-13"), "2020 page");
  assert(!mentionsDate(page("Fri 23 November"), "2026-11-13"), "23 is not 3");
  assert(!mentionsDate(page("Nothing about dates"), "2026-11-13"), "no date");
});

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
