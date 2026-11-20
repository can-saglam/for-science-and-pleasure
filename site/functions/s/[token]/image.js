// wegocan.com/s/<token>/image: the shared save's photo, fetched here so a
// visitor's browser (and a chat's preview fetcher) never calls the site the
// photo came from. Only the photo of the card behind the token, only
// bitmap images (an SVG can carry script), and only up to 5 MB.

import { photo, shared } from "../../../lib/share.js";

const TYPES = new Set(["image/jpeg", "image/png", "image/webp", "image/gif", "image/avif"]);
const MAX_BYTES = 5 * 1024 * 1024;

export async function onRequestGet({ params }) {
  const save = await shared(params.token);
  const source = save ? photo(save.card) : null;
  if (!source) return new Response("Not found", { status: 404 });

  let upstream;
  try {
    upstream = await fetch(source, {
      // JPEG and PNG first: chats' link previews don't all read WebP or AVIF.
      headers: { Accept: "image/jpeg,image/png;q=0.9,image/webp;q=0.8,image/gif;q=0.7,image/avif;q=0.5" },
      redirect: "follow",
      signal: AbortSignal.timeout(6000),
      cf: { cacheTtl: 86400, cacheEverything: true },
    });
  } catch {
    return new Response("Not found", { status: 404 });
  }
  const type = (upstream.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  const length = Number(upstream.headers.get("content-length") ?? 0);
  if (!upstream.ok || !TYPES.has(type) || length > MAX_BYTES) return new Response("Not found", { status: 404 });

  const body = await upstream.arrayBuffer();
  if (body.byteLength > MAX_BYTES) return new Response("Not found", { status: 404 });
  return new Response(body, {
    headers: {
      "Content-Type": type,
      "Cache-Control": "public, max-age=86400",
      "Content-Security-Policy": "default-src 'none'",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
