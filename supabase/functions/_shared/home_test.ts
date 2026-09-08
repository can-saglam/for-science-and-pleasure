import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  currencySymbol,
  geocodeNearHome,
  geocodeQuery,
  type Home,
  homeFromRow,
  homeLabel,
  homeToday,
  LONDON,
  namesCity,
  priceExamples,
} from "./home.ts";

const LISBON: Home = {
  locality: "Lisbon",
  country: "Portugal",
  timezone: "Europe/Lisbon",
  lat: 38.72,
  lng: -9.14,
};

Deno.test("homeLabel", () => {
  assertEquals(homeLabel(LONDON), "London, United Kingdom");
  assertEquals(homeLabel(LISBON), "Lisbon, Portugal");
});

Deno.test("homeToday: the date on the home clock, not UTC", () => {
  // 22:30 UTC on 7 Sep is 23:30 in London (BST) but already 8 Sep in Tokyo.
  const at = new Date("2026-09-07T22:30:00Z");
  assertEquals(homeToday(LONDON, at), "2026-09-07");
  assertEquals(homeToday({ ...LONDON, timezone: "Asia/Tokyo" }, at), "2026-09-08");
  // And 23:30 UTC in September *is* the next day in London — the reason
  // "today" can't be the server's UTC date.
  assertEquals(homeToday(LONDON, new Date("2026-09-07T23:30:00Z")), "2026-09-08");
  // 00:30 UTC on 8 Sep is still 7 Sep in New York.
  assertEquals(
    homeToday({ ...LONDON, timezone: "America/New_York" }, new Date("2026-09-08T00:30:00Z")),
    "2026-09-07",
  );
});

Deno.test("currency: known countries, case-insensitive, unknown → null", () => {
  assertEquals(currencySymbol("United Kingdom"), "£");
  assertEquals(currencySymbol("portugal"), "€");
  assertEquals(currencySymbol("Japan"), "¥");
  assertEquals(currencySymbol("Narnia"), null);
  assertEquals(priceExamples(LONDON), "e.g. 'Free', '£12', '£8–£15'");
  assert(priceExamples({ ...LONDON, country: "Narnia" }).includes("local currency"));
});

Deno.test("namesCity: home locality/country, or a 3-part address", () => {
  assert(namesCity("20 Deptford Broadway, London SE8 4PA", LONDON));
  assert(namesCity("Somewhere, United Kingdom", LONDON));
  assert(namesCity("12 Rue de Rivoli, Paris, France", LONDON));
  assert(!namesCity("20 Deptford Broadway", LONDON));
  assert(!namesCity("180 Strand, WC2R 1EA", LONDON)); // two parts, no city
  assert(!namesCity("12 Rue de Rivoli", LONDON));
});

Deno.test("geocodeQuery: home appended only when the address names no city", () => {
  assertEquals(
    geocodeQuery("20 Deptford Broadway", LONDON),
    "20 Deptford Broadway, London, United Kingdom",
  );
  assertEquals(
    geocodeQuery("20 Deptford Broadway, London SE8 4PA", LONDON),
    "20 Deptford Broadway, London SE8 4PA",
  );
  assertEquals(
    geocodeQuery("12 Rue de Rivoli, Paris, France", LONDON),
    "12 Rue de Rivoli, Paris, France",
  );
  assertEquals(geocodeQuery("Rua Augusta 100", LISBON), "Rua Augusta 100, Lisbon, Portugal");
});

Deno.test("geocodeNearHome: suffixed first, bare fallback, no double call when unsuffixed", async () => {
  const calls: string[] = [];
  const paris = { lat: 48.86, lng: 2.35 };
  // A geocoder that only knows the bare Paris street.
  const geocode = (q: string) => {
    calls.push(q);
    return Promise.resolve(q === "12 Rue de Rivoli" ? paris : null);
  };
  assertEquals(await geocodeNearHome(geocode, "12 Rue de Rivoli", LONDON), paris);
  assertEquals(calls, ["12 Rue de Rivoli, London, United Kingdom", "12 Rue de Rivoli"]);

  calls.length = 0;
  assertEquals(await geocodeNearHome(geocode, "12 Rue de Rivoli, Paris, France", LONDON), null);
  assertEquals(calls, ["12 Rue de Rivoli, Paris, France"]); // already names a city: one call

  calls.length = 0;
  const london = { lat: 51.5, lng: -0.1 };
  const hit = (q: string) => {
    calls.push(q);
    return Promise.resolve(london);
  };
  assertEquals(await geocodeNearHome(hit, "20 Deptford Broadway", LONDON), london);
  assertEquals(calls.length, 1); // suffixed query hit: no fallback
});

Deno.test("homeFromRow: null row → London; partial row fills from London", () => {
  assertEquals(homeFromRow(null), LONDON);
  assertEquals(
    homeFromRow({
      home_locality: "Lisbon",
      home_country: "Portugal",
      home_timezone: "Europe/Lisbon",
      home_lat: 38.72,
      home_lng: -9.14,
    }),
    LISBON,
  );
  const partial = homeFromRow({
    home_locality: "  ",
    home_country: null,
    home_timezone: null,
    home_lat: null,
    home_lng: null,
  });
  assertEquals(partial, LONDON);
  // A named home with no coordinates stays coordinate-less rather than
  // borrowing London's.
  const noCoords = homeFromRow({
    home_locality: "Lisbon",
    home_country: "Portugal",
    home_timezone: "Europe/Lisbon",
    home_lat: null,
    home_lng: null,
  });
  assertEquals(noCoords.lat, null);
});
