// place-photo: the thumbnail behind a Google place. Items keep a signed
// link here rather than Google's photo itself (their terms only let us
// keep the place ID); each request asks Google for the place's current
// first photo and redirects to it. Phones keep the image on disk after the
// first load, so this runs about once per phone per save.
//
// Public (image loaders send no auth), so the link is signed: only place
// IDs the parser issued get looked up.
import { freshPhotoUri, validPlacePhotoSignature } from "../_shared/places.ts";

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("method not allowed", { status: 405 });
  }
  const params = new URL(req.url).searchParams;
  const placeId = params.get("p") ?? "";
  if (!/^[A-Za-z0-9_-]{10,300}$/.test(placeId) ||
    !await validPlacePhotoSignature(placeId, params.get("s") ?? "")) {
    return new Response("not found", { status: 404 });
  }
  const photo = await freshPhotoUri(placeId);
  if (!photo) {
    return new Response("no photo", { status: 404, headers: { "Cache-Control": "no-store" } });
  }
  return new Response(null, {
    status: 302,
    headers: { Location: photo, "Cache-Control": "public, max-age=86400" },
  });
});
