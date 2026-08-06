// Dominant-colour extraction for card accents. Runs server-side at parse
// time (browsers can't sample cross-origin images because of CORS).
//
// Decoding uses pure-JS libraries (jpeg-js, pngjs), imported lazily and
// wrapped in try/catch: colour is best-effort and must never take the
// function down. imagescript was abandoned — its npm build requires native
// FFI codecs, which edge workers refuse (it crashed boots and every decode).
import { Buffer } from "node:buffer";

interface Rgba {
  data: Uint8Array;
  width: number;
  height: number;
}

async function decodeRgba(bytes: Uint8Array): Promise<Rgba | null> {
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    const m = await import("npm:jpeg-js@0.4.4");
    const decode = m.decode ?? m.default.decode;
    const img = decode(bytes, {
      useTArray: true,
      formatAsRGBA: true,
      maxMemoryUsageInMB: 256,
    });
    return { data: img.data, width: img.width, height: img.height };
  }
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const m = await import("npm:pngjs@7.0.0");
    const PNG = m.PNG ?? m.default.PNG;
    const img = PNG.sync.read(Buffer.from(bytes));
    return {
      data: new Uint8Array(img.data.buffer, img.data.byteOffset, img.data.byteLength),
      width: img.width,
      height: img.height,
    };
  }
  return null; // webp/avif/gif — colour is best-effort
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
function dominantFromRgba(
  data: Uint8Array | Uint8ClampedArray,
  stride = 1,
): string | null {
  const buckets = new Map<number, { n: number; r: number; g: number; b: number }>();
  let ar = 0, ag = 0, ab = 0, an = 0;

  for (let i = 0; i < data.length; i += 4 * stride) {
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
    const image = await decodeRgba(bytes);
    if (!image) return null;
    // Sample ~20k pixels instead of resizing — plenty for a dominant hue,
    // and keeps CPU bounded on large images.
    const stride = Math.max(1, Math.floor((image.width * image.height) / 20_000));
    return dominantFromRgba(image.data, stride);
  } catch {
    return null;
  }
}

export async function colorFromImageUrl(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, {
      redirect: "follow",
      signal: AbortSignal.timeout(10_000),
      // Prefer formats imagescript can decode; content-negotiating CDNs
      // otherwise happily send webp/avif, which decode to null.
      headers: {
        "User-Agent": UA,
        Accept: "image/jpeg,image/png;q=0.9,image/*;q=0.5",
      },
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
  // Scan every <meta> tag and read its attributes individually, so attribute
  // order, quoting style, and extra attributes in between don't matter.
  const wanted = [
    "og:image:secure_url",
    "og:image",
    "twitter:image",
    "twitter:image:src",
  ];
  const found = new Map<string, string>();
  for (const tag of html.matchAll(/<meta\b[^>]*>/gi)) {
    const attrs = tag[0];
    const key = attrs
      .match(/(?:property|name)\s*=\s*["']?([^"'\s>]+)/i)?.[1]
      ?.toLowerCase();
    if (!key || !wanted.includes(key) || found.has(key)) continue;
    const content = attrs.match(/content\s*=\s*("([^"]*)"|'([^']*)')/i);
    const value = content?.[2] ?? content?.[3];
    if (value) found.set(key, value);
  }
  for (const key of wanted) {
    const value = found.get(key);
    if (value) {
      try {
        return new URL(value.trim(), pageUrl).toString();
      } catch {
        continue;
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
