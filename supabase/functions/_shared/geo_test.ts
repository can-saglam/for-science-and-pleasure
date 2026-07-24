import { parseGoogleMapsUrl } from "./geo.ts";

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
