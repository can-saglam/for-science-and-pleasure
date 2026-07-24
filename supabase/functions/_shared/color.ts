// Dominant-colour extraction for card accents. Runs server-side at parse
// time (browsers can't sample cross-origin images because of CORS).
//
// imagescript is imported lazily: loading its codecs at module load has
// crashed workers at boot before (see locate), and colour is best-effort —
// a failure here must never take the whole function down.
type ImageClass = typeof import("npm:imagescript@1.3.0").Image;
let imagePromise: Promise<ImageClass> | null = null;
function loadImage(): Promise<ImageClass> {
  imagePromise ??= import("npm:imagescript@1.3.0").then((m) => m.Image);
  return imagePromise;
}

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

function toHex(r: number, g: number, b: number): string {
  const c = (v: number) => Math.round(v).toString(16).padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

// Prefer the most common saturated hue; greys, near-white and near-black
// pixels are ignored so page chrome doesn't win. Falls back to the overall
// average when the image is effectively monochrome.
function dominantFromRgba(data: Uint8Array | Uint8ClampedArray): string | null {
  const buckets = new Map<number, { n: number; r: number; g: number; b: number }>();
  let ar = 0, ag = 0, ab = 0, an = 0;

  for (let i = 0; i < data.length; i += 4) {
    const r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3];
    if (a < 128) continue;
    an++; ar += r; ag += g; ab += b;

    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const saturation = max === 0 ? 0 : (max - min) / max;
    const lightness = (max + min) / 510;
    if (saturation < 0.18 || lightness < 0.12 || lightness > 0.92) continue;

    const key = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
    const entry = buckets.get(key) ?? { n: 0, r: 0, g: 0, b: 0 };
    entry.n++; entry.r += r; entry.g += g; entry.b += b;
    buckets.set(key, entry);
  }

  let best: { n: number; r: number; g: number; b: number } | null = null;
  for (const entry of buckets.values()) {
    if (!best || entry.n > best.n) best = entry;
  }
  if (best && best.n >= 8) return toHex(best.r / best.n, best.g / best.n, best.b / best.n);
  if (an > 0) return toHex(ar / an, ag / an, ab / an);
  return null;
}

export async function colorFromImageBytes(bytes: Uint8Array): Promise<string | null> {
  try {
    const Image = await loadImage();
    const image = await Image.decode(bytes);
    image.resize(48, Image.RESIZE_AUTO);
    return dominantFromRgba(image.bitmap);
  } catch {
    return null; // unsupported format (e.g. webp) — colour is best-effort
  }
}

export async function colorFromImageUrl(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, {
      redirect: "follow",
      signal: AbortSignal.timeout(10_000),
      headers: { "User-Agent": UA, Accept: "image/*" },
    });
    if (!res.ok) return null;
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.length > 8_000_000) return null;
    return await colorFromImageBytes(bytes);
  } catch {
    return null;
  }
}

export function ogImageFromHtml(html: string, pageUrl: string): string | null {
  const patterns = [
    /<meta[^>]+property=["']og:image(?::secure_url)?["'][^>]+content=["']([^"']+)["']/i,
    /<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image(?::secure_url)?["']/i,
    /<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']/i,
  ];
  for (const re of patterns) {
    const m = html.match(re);
    if (m) {
      try {
        return new URL(m[1], pageUrl).toString();
      } catch {
        return null;
      }
    }
  }
  return null;
}

export async function colorFromPageUrl(pageUrl: string): Promise<string | null> {
  try {
    const res = await fetch(pageUrl, {
      redirect: "follow",
      signal: AbortSignal.timeout(10_000),
      headers: { "User-Agent": UA, Accept: "text/html,application/xhtml+xml" },
    });
    if (!res.ok) return null;
    const image = ogImageFromHtml(await res.text(), pageUrl);
    return image ? await colorFromImageUrl(image) : null;
  } catch {
    return null;
  }
}
