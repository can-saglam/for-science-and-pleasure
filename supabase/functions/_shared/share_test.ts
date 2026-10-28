import { assert, assertEquals } from "jsr:@std/assert";
import { firstName, publicInvite, sharedCard, shareToken } from "./share.ts";

Deno.test("a shared card keeps the public fields and drops the rest", () => {
  const card = sharedCard({
    kind: "event",
    title: "  Salman Toor  ",
    venue: "The Courtauld",
    starts_on: "2026-10-09",
    ends_on: "18 January",
    url: "https://courtauld.ac.uk/whats-on/salman-toor/",
    image_url: "javascript:alert(1)",
    lat: 51.51,
    lng: 500,
    notes: "bring Ozge",
    plan_on: "2026-11-01",
    showings: [{ date: "2026-10-10", time: "19:30", note: "Q&A" }, { date: "soon" }],
  })!;
  assertEquals(card.title, "Salman Toor");
  assertEquals(card.starts_on, "2026-10-09");
  assertEquals(card.ends_on, null);
  assertEquals(card.image_url, null);
  assertEquals(card.lat, 51.51);
  assertEquals(card.lng, null);
  assertEquals(card.showings, [{ date: "2026-10-10", time: "19:30", note: "Q&A" }]);
  assertEquals(card.source, "shared");
  assert(!("notes" in card) && !("plan_on" in card));
});

Deno.test("something that isn't a card isn't shared", () => {
  assertEquals(sharedCard(null), null);
  assertEquals(sharedCard({ kind: "event", title: "  " }), null);
  assertEquals(sharedCard({ kind: "party", title: "Bao" }), null);
});

Deno.test("a shared save names its sender by first name only", () => {
  assertEquals(firstName("  Can Sağlam "), "Can");
  assertEquals(firstName("Özge"), "Özge");
  assertEquals(firstName("   "), null);
  assertEquals(firstName(null), null);
});

Deno.test("share tokens are ten unambiguous characters", () => {
  const tokens = new Set(Array.from({ length: 500 }, shareToken));
  assertEquals(tokens.size, 500);
  for (const t of tokens) assert(/^[A-HJ-NP-Za-km-z2-9]{10}$/.test(t), t);
});

Deno.test("an invite's page learns first names and whether it still works", () => {
  const now = new Date("2026-10-27T12:00:00Z");
  const live = { expires_at: "2026-11-01T00:00:00Z", revoked_at: null };
  const members = [
    { display_name: "Can Sağlam", avatar_colour: "coral" },
    { display_name: "Joyce Lee", avatar_colour: null },
    { display_name: null, avatar_colour: "mint" },
  ];
  assertEquals(publicInvite(live, "Can Sağlam", members, now), {
    status: "ok",
    from: "Can",
    members: [{ name: "Can", colour: "coral" }, { name: "Joyce", colour: null }],
  });
  assertEquals(publicInvite(live, null, [...members, members[0]], now).status, "full");
  assertEquals(
    publicInvite({ ...live, expires_at: "2026-10-20T00:00:00Z" }, "Can", members, now),
    { status: "expired", from: "Can", members: [] },
  );
  assertEquals(publicInvite({ ...live, revoked_at: "2026-10-26T00:00:00Z" }, "Can", members, now).status, "expired");
});
