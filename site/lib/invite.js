// The share function's invite lookup, as Cloudflare's side of
// wegocan.com/join/<code> reads it.

const API = "https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/share";

/** "KV7P2M" from "kv7-p2m", or null when it can't be a code. */
export function cleanCode(raw) {
  const code = decodeURIComponent(String(raw)).toUpperCase().replace(/[^A-Z0-9]/g, "");
  return /^[A-HJ-NP-Z2-9]{6}$/.test(code) ? code : null;
}

/** { status, from, members } for a code, or null when it's malformed (or
 * slow). The visitor's address goes along, so the share function limits
 * guessing per person rather than per Cloudflare server. */
export async function invite(raw, { visitor, siteKey } = {}) {
  const code = cleanCode(raw);
  if (!code) return null;
  const headers = visitor && siteKey ? { "x-visitor-ip": visitor, "x-site-key": siteKey } : {};
  try {
    const res = await fetch(`${API}?i=${code}`, { headers, signal: AbortSignal.timeout(4000) });
    if (!res.ok) return null;
    const body = await res.json();
    return body.status ? body : null;
  } catch {
    return null;
  }
}

/** "Can", "Can and Joyce", "Can, Joyce and Sam". */
export function names(list) {
  if (list.length < 2) return list[0] ?? "";
  return `${list.slice(0, -1).join(", ")} and ${list.at(-1)}`;
}
