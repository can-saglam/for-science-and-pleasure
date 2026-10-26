// The share function, as Cloudflare's side of wegocan.com/s/<token> reads it.

const API = "https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/share";

/** { card, from } for a token, or null when it's gone (or slow). */
export async function shared(token) {
  const clean = String(token).replace(/[^A-Za-z0-9]/g, "");
  if (clean.length !== 10) return null;
  try {
    const res = await fetch(`${API}?t=${clean}`, { signal: AbortSignal.timeout(4000), cf: { cacheTtl: 60 } });
    if (!res.ok) return null;
    const body = await res.json();
    return body.card?.title ? { card: body.card, from: body.from ?? null, token: clean } : null;
  } catch {
    return null;
  }
}

// Google's place photos can't be shown without their credit, which a
// preview has no room for; those saves go without.
export function photo(card) {
  const url = card.image_url;
  return url && /^https?:\/\//.test(url) && !url.includes("/functions/v1/place-photo") ? url : null;
}
