import { assert, assertEquals } from "jsr:@std/assert";
import { keepable, uncarded, withPickLook } from "./pick_cards.ts";
import { type PickCard, placeCard, type Suggestion } from "./suggestions.ts";

const place: Suggestion = {
  title: "Cafe OTO",
  url: "https://www.cafeoto.co.uk/",
  kind: "place",
  venue: "Dalston",
  starts_on: null,
  ends_on: null,
  category: "venue",
  about: "Experimental music in a no-frills room.",
  image: "https://example.org/oto.jpg",
  color: "#223344",
};

const match = {
  id: "ChIJoto",
  name: "Cafe OTO",
  address: "18-22 Ashwin St, London E8 3DL",
  lat: 51.548,
  lng: -0.075,
  photo: null,
  credit: null,
  types: ["bar", "establishment"],
};

Deno.test("a place's card comes from its Google match, shaped as a lookup's", () => {
  const card = placeCard(place, match, place.image!, place.color!)!;
  assertEquals(card.kind, "place");
  assertEquals(card.title, "Cafe OTO");
  assertEquals(card.area, "Dalston");
  assertEquals(card.address, "18-22 Ashwin St, London E8 3DL");
  assertEquals([card.lat, card.lng], [51.548, -0.075]);
  assertEquals(card.place_id, "ChIJoto");
  assertEquals(card.summary, "Experimental music in a no-frills room.");
  assertEquals(card.url, place.url);
  assertEquals(card.image_url, place.image);
});

Deno.test("a match that's a neighbourhood gives no hours, and no pin gives no card", () => {
  assertEquals(placeCard(place, { ...match, types: ["neighborhood", "political"] }, null, null)?.place_id, null);
  assertEquals(placeCard(place, { ...match, lat: null, lng: null }, null, null), null);
});

Deno.test("only a pinned card is kept for everyone", () => {
  const card = placeCard(place, match, null, null)!;
  assert(keepable(card));
  assert(!keepable({ ...card, lat: null, lng: null } as PickCard));
});

Deno.test("the pick's picture stands in when the page gave none", () => {
  const card = placeCard(place, match, null, null)!;
  const dressed = withPickLook(card, place);
  assertEquals(dressed.image_url, place.image);
  assertEquals(dressed.color, place.color);
  const own = withPickLook({ ...card, image_url: "https://example.org/own.jpg", color: "#000000" }, place);
  assertEquals(own.image_url, "https://example.org/own.jpg");
  const thumb = withPickLook({ ...card, image_url: "https://example.org/images/x=/1/width-56/own.jpg" }, place);
  assertEquals(thumb.image_url, place.image);
});

Deno.test("a pick tried once isn't looked up again", () => {
  assert(uncarded([place]));
  assert(!uncarded([{ ...place, card: null }]));
});
