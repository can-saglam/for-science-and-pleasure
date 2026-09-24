import { assert, assertEquals } from "jsr:@std/assert@1";
import { LONDON, UNSET } from "./home.ts";
import {
  metresBetween,
  placePhotoLink,
  placeQuery,
  sameName,
  validPlacePhotoSignature,
} from "./places.ts";

Deno.test("sameName: branch suffixes and filler words still match", () => {
  assert(sameName("Dishoom", "Dishoom King's Cross"));
  assert(sameName("The Barbican Centre", "Barbican"));
  assert(sameName("Café Deco", "Cafe Deco"));
  assert(sameName("Bao & Bing", "Bao and Bing"));
  assert(sameName("Kiln", "Kiln Soho"));
  assert(sameName("Padella Borough Market", "Padella"));
  assert(sameName("St. John Bread and Wine", "St. JOHN Bread & Wine Spitalfields"));
  assert(sameName("Bistro Freddie", "Bistro Freddie's"));
});

Deno.test("sameName: a different place doesn't", () => {
  assert(!sameName("Kiln", "Smoking Goat"));
  assert(!sameName("Tate Modern", "Tate Britain Café"));
  assert(!sameName("The Restaurant", "Dishoom"));
  assert(!sameName("", "Dishoom"));
});

Deno.test("placeQuery: narrows by address, else area, and adds home only when needed", () => {
  assertEquals(
    placeQuery("Kiln", { address: "58 Brewer St", area: "Soho" }, LONDON),
    "Kiln, 58 Brewer St, London",
  );
  assertEquals(placeQuery("Kiln", { area: "Soho" }, LONDON), "Kiln, Soho, London");
  assertEquals(
    placeQuery("Le Chateaubriand", { address: "129 Av. Parmentier, Paris, France" }, LONDON),
    "Le Chateaubriand, 129 Av. Parmentier, Paris, France",
  );
  assertEquals(placeQuery("Kiln", {}, UNSET), "Kiln");
});

Deno.test("metresBetween: city-scale distances", () => {
  const kingsCross = { lat: 51.5362, lng: -0.1255 };
  const coventGarden = { lat: 51.5124, lng: -0.1263 };
  const d = metresBetween(kingsCross, coventGarden);
  assert(d > 2500 && d < 2800, `got ${d}`);
  assertEquals(metresBetween(kingsCross, kingsCross), 0);
});

Deno.test("placePhotoLink: signed for its own place only", async () => {
  Deno.env.set("SUPABASE_URL", "https://example.supabase.co");
  Deno.env.set("GOOGLE_MAPS_API_KEY", "test-secret");
  const raw = await placePhotoLink("ChIJabc123def456", "Ana Silva");
  assert(raw.includes("by=Ana%20Silva"), raw);
  const link = new URL(raw);
  assertEquals(link.pathname, "/functions/v1/place-photo");
  assertEquals(link.searchParams.get("by"), "Ana Silva");
  const sig = link.searchParams.get("s")!;
  assert(await validPlacePhotoSignature("ChIJabc123def456", sig));
  assert(!await validPlacePhotoSignature("ChIJsomethingElse", sig));
  assert(!await validPlacePhotoSignature("ChIJabc123def456", ""));
});
