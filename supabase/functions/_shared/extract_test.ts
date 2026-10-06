import {
  cleanLink,
  cleanShowings,
  isAnchored,
  isThisRun,
  jsonLdEvents,
  ldClosing,
  linkKey,
  mentionsDate,
  pageFromHtml,
  pageLink,
} from "./extract.ts";

Deno.test("phone-read pages: plain links only, bot walls refused", () => {
  assert(pageLink("look https://whatson.bfi.org.uk/lff/Online/x.asp?a::b") === "https://whatson.bfi.org.uk/lff/Online/x.asp?a::b", "a page");
  assert(pageLink("https://maps.app.goo.gl/abc") === null, "maps pins read their own way");
  assert(pageLink("https://goo.gl/xyz") === null && pageLink("https://g.co/kgs/abc") === null, "short links may be pins");
  assert(pageLink("https://www.instagram.com/p/abc/") === null, "so do social posts");
  assert(pageLink("Frida Kahlo at Tate Modern") === null, "no link");

  const film = pageFromHtml(
    `<html><head><title>The History of Concrete</title><meta property="og:image" content="/films/concrete.jpeg" /></head><body>Tue 13 Oct 18:15</body></html>`,
    "https://whatson.bfi.org.uk/lff/Online/default.asp",
  );
  assert(film?.ogImage === "https://whatson.bfi.org.uk/films/concrete.jpeg", `image: ${film?.ogImage}`);
  assert(film?.text.includes("18:15"), "the page's text");
  assert(pageFromHtml("<title>Just a moment...</title><body>Enable JavaScript and cookies to continue</body>", "https://x.org/") === null, "a wall is no page");
});

Deno.test("showings: real days from today, in order, one each", () => {
  const today = "2026-10-05";
  const lff = cleanShowings([
    { date: "2026-10-14", time: "20:35", note: " Relaxed screening " },
    { date: "2026-10-13", time: "18:15", note: null },
    { date: "2026-10-13", time: "18:15", note: "again" },
    { date: "2026-10-01", time: "19:00", note: null },
    { date: "2026-02-31", time: "19:00", note: null },
    { date: "2026-10-15", time: "9:05", note: "" },
    { date: "2026-10-16", time: "25:00", note: null },
  ], "event", today);
  assert(
    JSON.stringify(lff) === JSON.stringify([
      { date: "2026-10-13", time: "18:15", note: null },
      { date: "2026-10-14", time: "20:35", note: "Relaxed screening" },
      { date: "2026-10-15", time: "09:05", note: null },
      { date: "2026-10-16", time: null, note: null },
    ]),
    `cleaned: ${JSON.stringify(lff)}`,
  );
  assert(cleanShowings([{ date: "2026-10-13", time: null, note: null }], "event", today) === null, "a lone day adds nothing");
  assert(cleanShowings([{ date: "2026-10-13", time: "19:30", note: null }], "event", today)?.length === 1, "a lone time does");
  assert(cleanShowings([{ date: "2026-10-13", time: "19:30", note: null }], "place", today) === null, "places have none");
  assert(cleanShowings(null, "event", today) === null, "none given");
  const many = Array.from({ length: 40 }, (_, i) => ({ date: "2026-11-01", time: `${String(10 + (i % 12)).padStart(2, "0")}:${String(i).padStart(2, "0")}`, note: null }));
  assert(cleanShowings(many, "event", today)?.length === 30, "capped");
});

const ld = (json: unknown) => `<script type="application/ld+json">${JSON.stringify(json)}</script>`;

Deno.test("a closing day only the structured data gives is read", () => {
  // The V&A prints "Opens Saturday, 7 November 2026" and nothing else.
  const vam = `<p>Opens Saturday, 7 November 2026</p>` + ld({
    "@context": "http://schema.org",
    "@type": "ExhibitionEvent",
    name: "Constantinople to Istanbul: One City, Two Empires",
    startDate: "2026-11-07",
    endDate: "2027-05-09",
  });
  const events = jsonLdEvents(vam);
  assert(events.length === 1 && events[0].end === "2027-05-09", "read the ExhibitionEvent");
  const card = { kind: "event" as const, starts_on: "2026-11-07" };
  assert(ldClosing(events, card) === "2027-05-09", "closing day");
  assert(ldClosing(events, { ...card, starts_on: "2026-11-08" }) === null, "a different run");
  assert(ldClosing(events, { kind: "place", starts_on: "2026-11-07" }) === null, "places have no run");
  assert(ldClosing(events, { ...card, starts_on: null }) === null, "no start to match");
});

Deno.test("structured data in graphs, lists and timestamps", () => {
  const graph = jsonLdEvents(ld({
    "@graph": [
      { "@type": "Organization", name: "Gallery" },
      { "@type": ["Event", "VisualArtsEvent"], name: "Show", startDate: "2026-10-01T10:00:00+01:00", endDate: "2027-01-10T18:00:00+00:00" },
    ],
  }));
  assert(graph.length === 1 && graph[0].start === "2026-10-01" && graph[0].end === "2027-01-10", "graph, typed array, timestamps");
  const list = jsonLdEvents(ld({
    "@type": "ItemList",
    itemListElement: [{ "@type": "ListItem", item: { "@type": "Event", name: "Gig", startDate: "2026-12-01" } }],
  }));
  assert(list.length === 1 && list[0].end === null, "list item, no end");
  assert(jsonLdEvents(`<script type="application/ld+json">{not json</script>`).length === 0, "malformed block");
});

Deno.test("an unclear closing day stays empty", () => {
  const card = { kind: "event" as const, starts_on: "2026-11-07" };
  const twoRuns = [
    { name: "A", start: "2026-11-07", end: "2027-01-01" },
    { name: "B", start: "2026-11-07", end: "2027-02-01" },
  ];
  assert(ldClosing(twoRuns, card) === null, "two end dates for one opening");
  assert(ldClosing([{ name: "A", start: "2026-11-07", end: "2026-01-01" }], card) === null, "ends before it opens");
  assert(ldClosing([{ name: "A", start: "2026-11-07", end: null }], card) === null, "no end given");
  assert(ldClosing([{ name: "Gig", start: "2026-11-07", end: "2026-11-08" }], card) === null, "a night past midnight");
  assert(ldClosing([{ name: "A", start: "2026-11-07", end: "2026-11-07" }], card) === "2026-11-07", "one day");
  assert(
    ldClosing([{ name: "A", start: "2026-12-31", end: "2027-01-01" }], { ...card, starts_on: "2026-12-31" }) === null,
    "New Year's Eve past midnight",
  );
});

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
