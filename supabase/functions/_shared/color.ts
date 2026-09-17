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
        return httpsOnly(new URL(value.trim(), pageUrl).toString());
      } catch {
        continue;
      }
    }
  }
  return null;
}

// iOS blocks plain-http images (ATS), and Squarespace et al. still emit
// http:// og:image URLs. Modern CDNs all serve https.
function httpsOnly(url: string): string {
  return url.replace(/^http:\/\//i, "https://");
}

// JSON-LD "image" values come as a string, an array, or an ImageObject.
// Only an ImageObject's url counts — a WebSite/Organization node's url is
// just the homepage, not a picture. Every image found is ranked by the
// node it hangs off: the thing the page is about (an Event, a Place, an
// Article) beats generic page nodes, which beat the site's Organization —
// SEO plugins put the company logo first in the graph, ahead of the
// festival's own poster.
const SUBJECT_TYPE_RE =
  /event|festival|exhibition|place|business|restaurant|cafe|bar|museum|gallery|article|creativework|product|visualartwork/i;
const BRAND_TYPE_RE = /organization|person|brand/i;

function jsonLdImages(
  node: unknown,
  out: { url: string; rank: number }[],
  rank = 1,
): void {
  if (typeof node === "string") {
    out.push({ url: node, rank });
  } else if (Array.isArray(node)) {
    for (const entry of node) jsonLdImages(entry, out, rank);
  } else if (node && typeof node === "object") {
    const obj = node as Record<string, unknown>;
    const type = typeof obj["@type"] === "string" ? obj["@type"] : "";
    if (/^imageobject$/i.test(type) || (/image/i.test(type) && (obj.contentUrl || obj.url))) {
      jsonLdImages(obj.contentUrl ?? obj.url ?? null, out, rank);
      return;
    }
    const own = SUBJECT_TYPE_RE.test(type) ? 0 : BRAND_TYPE_RE.test(type) ? 2 : rank;
    jsonLdImages(obj.image ?? null, out, own);
    jsonLdImages(obj["@graph"] ?? null, out, own);
  }
}

/// Best photo for a page: og:image, then JSON-LD, then the largest content
/// <img> — small venue sites often skip social meta tags entirely.
export function heroImageFromHtml(html: string, pageUrl: string): string | null {
  const og = ogImageFromHtml(html, pageUrl);
  if (og) return og;

  const ld: { url: string; rank: number }[] = [];
  for (const block of html.matchAll(
    /<script\b[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi,
  )) {
    try {
      jsonLdImages(JSON.parse(block[1]), ld);
    } catch {
      // malformed block — keep looking
    }
  }
  // Stable: ties keep document order.
  for (const { url } of ld.sort((a, b) => a.rank - b.rank)) {
    try {
      return httpsOnly(new URL(url, pageUrl).toString());
    } catch {
      continue;
    }
  }

  let best: { src: string; width: number } | null = null;
  for (const tag of html.matchAll(/<(?:img|source)\b[^>]*>/gi)) {
    const candidate = largestImageCandidate(tag[0]);
    if (!candidate) continue;
    if (!best || candidate.width > best.width) best = candidate;
  }
  if (best) {
    try {
      return httpsOnly(new URL(best.src.replace(/&amp;/g, "&"), pageUrl).toString());
    } catch {
      return null;
    }
  }
  return null;
}

/// Page chrome never makes a good thumbnail.
const CHROME_RE = /logo|icon|sprite|avatar|badge|\.svg/i;

/// The biggest picture an <img>/<source> tag offers, with the best width
/// we can infer for it, or null when it's chrome or plainly small. Sizes
/// come from wherever a site puts them: a width attribute, a srcset's `w`
/// descriptors, a `?width=` query, or the WordPress size suffix on the
/// filename (`-800x530.jpg`, `-scaled.jpg`) — small venue sites rarely
/// set width= and lazy-load everything through data-src/srcset.
export function largestImageCandidate(
  tagAttrs: string,
): { src: string; width: number } | null {
  const attr = (name: string) =>
    tagAttrs.match(new RegExp(`\\b${name}\\s*=\\s*["']([^"']+)["']`, "i"))?.[1];

  let src = attr("src") ?? attr("data-src") ?? attr("data-lazy-src") ?? null;
  let width = Number(
    tagAttrs.match(/\bwidth\s*=\s*["']?(\d+)/i)?.[1] ??
      tagAttrs.match(/\bstyle\s*=\s*["'][^"']*\bwidth\s*:\s*(\d+)px/i)?.[1] ??
      0,
  );

  // srcset: take the widest entry; it names the size outright.
  const srcset = attr("srcset") ?? attr("data-srcset") ?? attr("data-lazy-srcset");
  if (srcset) {
    for (const entry of srcset.split(",")) {
      const [url, descriptor] = entry.trim().split(/\s+/);
      const w = descriptor?.match(/^(\d+)w$/)?.[1];
      if (!url || !w) continue;
      if (Number(w) > width) {
        width = Number(w);
        src = url;
      }
    }
  }
  if (!src || CHROME_RE.test(src)) return null;

  if (!width) {
    width = Number(
      src.match(/[?&](?:w|width)=(\d+)/i)?.[1] ??
        src.match(/-(\d{3,4})x\d{3,4}\.(?:jpe?g|png|webp|avif)/i)?.[1] ??
        (/-scaled\.(?:jpe?g|png|webp)/i.test(src) ? 1000 : 0),
    );
  }
  return width >= 500 ? { src, width } : null;
}

/// Fetch a page and pull its best photo — for sites the model named when
/// the saved link itself had none.
export async function heroImageFromUrl(pageUrl: string): Promise<string | null> {
  try {
    const res = await fetch(pageUrl, {
      redirect: "follow",
      signal: AbortSignal.timeout(10_000),
      headers: { "User-Agent": UA, Accept: "text/html,application/xhtml+xml" },
    });
    if (!res.ok) return null;
    const html = (await res.text()).slice(0, 600_000);
    return heroImageFromHtml(html, res.url || pageUrl);
  } catch {
    return null;
  }
}

/// Last-resort cover for a named venue or festival when the page itself
/// had no picture. Wikipedia's summary endpoint is free and has decent
/// coverage for museums, festivals and well-known rooms — not for a
/// neighbourhood restaurant. Callers must only try a specific name.
const WIKI_UA = "CanWeGo/1.0 (https://canwego.app; thumbnail fallback)";

export function wikipediaQueries(card: { title?: string | null; venue?: string | null }): string[] {
  const out: string[] = [];
  const add = (raw?: string | null) => {
    const q = (raw ?? "").replace(/\s+/g, " ").trim();
    if (q.length < 8) return;
    if (/^(new item|untitled)$/i.test(q)) return;
    if (!out.some((x) => x.toLowerCase() === q.toLowerCase())) out.push(q);
  };
  add(card.venue);
  add(card.title);
  return out.slice(0, 2);
}

/// True when query and Wikipedia title share a real word — stops "Kin"
/// matching a random disambiguation hit, and a mistyped venue matching
/// the first search-ish summary.
export function wikipediaTitlesOverlap(query: string, title: string): boolean {
  const tokens = (s: string) =>
    s.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 4);
  const have = new Set(tokens(query));
  return tokens(title).some((t) => have.has(t));
}

export function wikipediaThumbnailFromSummary(json: unknown, query: string): string | null {
  if (!json || typeof json !== "object") return null;
  const page = json as Record<string, unknown>;
  if (page.type === "disambiguation") return null;
  const title = typeof page.title === "string" ? page.title : "";
  if (!wikipediaTitlesOverlap(query, title)) return null;
  const original = page.originalimage as { source?: string } | undefined;
  const thumb = page.thumbnail as { source?: string } | undefined;
  const src = original?.source ?? thumb?.source;
  return typeof src === "string" && /^https:\/\//i.test(src) ? src : null;
}

export async function wikipediaImage(query: string): Promise<string | null> {
  const path = encodeURIComponent(query.replace(/ /g, "_"));
  try {
    const res = await fetch(
      `https://en.wikipedia.org/api/rest_v1/page/summary/${path}`,
      {
        signal: AbortSignal.timeout(8_000),
        headers: { "User-Agent": WIKI_UA, Accept: "application/json" },
      },
    );
    if (!res.ok) return null;
    return wikipediaThumbnailFromSummary(await res.json(), query);
  } catch {
    return null;
  }
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
