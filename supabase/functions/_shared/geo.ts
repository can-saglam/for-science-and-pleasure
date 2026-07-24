// Small, dependency-free helpers shared by functions. Kept separate from
// extract.ts so that functions which only geocode (e.g. locate) don't pull in
// the imagescript dependency, whose native codec loading crashes the worker.

// Free OSM geocoder — used only server-side to attach coordinates so the app
// can do distance-based "nearby" suggestions and Google Maps directions.
export async function geocode(query: string): Promise<{ lat: number; lng: number } | null> {
  try {
    const res = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(query)}`,
      {
        headers: { "User-Agent": "for-science-and-pleasure/1.0" },
        signal: AbortSignal.timeout(8_000),
      },
    );
    if (!res.ok) return null;
    const arr = await res.json();
    if (!arr?.[0]?.lat) return null;
    return { lat: parseFloat(arr[0].lat), lng: parseFloat(arr[0].lon) };
  } catch {
    return null;
  }
}

export interface MapsLinkInfo {
  name: string | null;
  lat: number | null;
  lng: number | null;
}

// Google Maps pages are tens of MB of JS and crash the worker if fetched, but
// the URL itself already carries the place name and pin coordinates.
export function parseGoogleMapsUrl(url: string): MapsLinkInfo | null {
  try {
    const u = new URL(url);
    const isMaps =
      (/(^|\.)google\.[a-z.]+$/.test(u.hostname) &&
        u.pathname.startsWith("/maps")) ||
      u.hostname === "maps.google.com";
    if (!isMaps) return null;
    const place = u.pathname.match(/\/place\/([^/]+)/)?.[1];
    const name = place
      ? decodeURIComponent(place.replace(/\+/g, " "))
      : u.searchParams.get("q");
    // !3d…!4d… is the pin itself; @lat,lng is just the viewport centre.
    const pin = url.match(/!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/);
    const at = url.match(/@(-?\d+\.\d+),(-?\d+\.\d+)/);
    const m = pin ?? at;
    return {
      name: name?.trim() || null,
      lat: m ? parseFloat(m[1]) : null,
      lng: m ? parseFloat(m[2]) : null,
    };
  } catch {
    return null;
  }
}

// Share-sheet links (maps.app.goo.gl) are opaque; follow the redirect to the
// full URL without reading the (huge) body, then parse that.
export async function resolveMapsLink(url: string): Promise<MapsLinkInfo | null> {
  const direct = parseGoogleMapsUrl(url);
  if (direct) return direct;
  try {
    const host = new URL(url).hostname;
    if (!/^(maps\.app\.goo\.gl|goo\.gl)$/.test(host)) return null;
    const res = await fetch(url, {
      redirect: "follow",
      signal: AbortSignal.timeout(10_000),
    });
    res.body?.cancel();
    return parseGoogleMapsUrl(res.url);
  } catch {
    return null;
  }
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-ingest-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
