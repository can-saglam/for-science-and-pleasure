import { parseGoogleMapsUrl, photonMatches } from "./geo.ts";

Deno.test("photon hit counts only when its street or name is in the address", () => {
  const ok = (props: { name?: string; street?: string }, q: string, want: boolean) => {
    if (photonMatches(props, q) !== want) throw new Error(`${JSON.stringify(props)} vs ${q}: expected ${want}`);
  };
  ok({ name: "Cromwell Road" }, "Cromwell Road, London, SW7 2RL", true);
  ok({ name: "Somerset House", street: "Strand" }, "Somerset House, Strand, London WC2R 0RN", true);
  ok({ street: "St John Street" }, "26 St. John Street, London, EC1M 4AY", true);
  ok({ street: "Acre Lane" }, "112 Acre Ln, London SW2 5RA, UK", true);
  ok({ name: "Nunhead" }, "Nunhead, London, United Kingdom", true);
  ok({ street: "Belvedere Road" }, "Southbank Centre, Belvedere Rd, London", true);
  // Photon's nearest guesses for streets that aren't in London at all.
  ok({ name: "The Rivoli Bar", street: "Piccadilly" }, "12 Rue de Rivoli, London, United Kingdom", false);
  ok({ name: "London Canal Museum", street: "New Wharf Road" }, "Kastanienallee 12, London, United Kingdom", false);
  ok({ name: "Somewhere", street: "Lonsdale Road" }, "Somewhere vague, London, United Kingdom", false);
  ok({}, "Anything", false);
});

const sudu =
  "https://www.google.com/maps/place/SUDU+-+Malaysian+Eatery/@51.5319966,-0.2103918,15z/data=!4m6!3m5!1s0x48761f7f70121af:0xd6b4b032ad358526!8m2!3d51.5343592!4d-0.2047753!16s%2Fg%2F11n_s11bb7?entry=ttu&g_ep=EgoyMDI2MDcyMS4wIKXMDSoASAFQAw%3D%3D";

Deno.test("full place URL: name + pin coords (not viewport)", () => {
  const info = parseGoogleMapsUrl(sudu);
  if (
    info?.name !== "SUDU - Malaysian Eatery" ||
    info.lat !== 51.5343592 ||
    info.lng !== -0.2047753
  ) {
    throw new Error(`unexpected: ${JSON.stringify(info)}`);
  }
});

Deno.test("viewport-only URL falls back to @ coords", () => {
  const info = parseGoogleMapsUrl(
    "https://www.google.com/maps/place/Somewhere/@51.5,-0.1,15z",
  );
  if (info?.name !== "Somewhere" || info.lat !== 51.5 || info.lng !== -0.1) {
    throw new Error(`unexpected: ${JSON.stringify(info)}`);
  }
});

Deno.test("q= search URL", () => {
  const info = parseGoogleMapsUrl(
    "https://maps.google.com/?q=Kiln+Soho+London",
  );
  if (info?.name !== "Kiln Soho London") {
    throw new Error(`unexpected: ${JSON.stringify(info)}`);
  }
});

Deno.test("non-maps URL is ignored", () => {
  if (parseGoogleMapsUrl("https://www.tate.org.uk/whats-on") !== null) {
    throw new Error("should be null");
  }
});
