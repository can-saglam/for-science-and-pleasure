// place-photo: the thumbnail behind a Google place. Items keep a signed
// link here rather than Google's photo itself (their terms only let us
// keep the place ID); each request asks Google for the place's current
// first photo and redirects to it. Phones keep the image on disk after the
// first load, so this runs about once per phone per save.
//
// Public (image loaders send no auth), so the link is signed: only place
// IDs the parser issued get looked up.
//
// A place's answer is kept for an hour, so a link fetched over and over
// (it can be public, in a shared card) costs Google one lookup an hour.
import { admin } from "../_shared/groups.ts";
import { freshPhotoUri, validPlacePhotoSignature } from "../_shared/places.ts";

const KEEP_MS = 60 * 60 * 1000;

async function photoFor(placeId: string): Promise<string | null> {
  const db = admin();
  const { data } = await db.from("place_photo_cache").select("uri, fetched_at").eq("place_id", placeId).maybeSingle();
  if (data && Date.now() - new Date(data.fetched_at).getTime() < KEEP_MS) return data.uri;
  const uri = await freshPhotoUri(placeId);
  const { error } = await db.from("place_photo_cache")
    .upsert({ place_id: placeId, uri, fetched_at: new Date().toISOString() });
  if (error) console.warn("place_photo_cache", error.message);
  return uri;
}

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
  const photo = await photoFor(placeId);
  if (!photo) {
    return new Response("no photo", { status: 404, headers: { "Cache-Control": "no-store" } });
  }
  return new Response(null, {
    status: 302,
    headers: { Location: photo, "Cache-Control": "public, max-age=86400" },
  });
});
