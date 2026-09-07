// Social links: Instagram, TikTok, Facebook. These hosts serve a login wall
// to plain fetches, so the parser used to see nothing but the URL slug. What
// *is* reachable without auth:
//
//   TikTok     the public oEmbed endpoint — caption, author, cover image.
//   Instagram  the post page's own <meta og:…> tags when fetched with a
//              mobile Safari UA — caption (inside og:description), author,
//              cover image. Datacenter IPs are sometimes served the wall
//              instead; that comes back as null and the app's on-device
//              fetch (residential IP) is the next layer.
//   Facebook   nothing reliable; null, so the app asks the user.
//
// Cover images from both CDNs carry expiring signatures. They are good for
// reading on-screen text and picking the accent colour *now*, never for
// storing as the thumbnail — the venue's own site supplies that.

export type SocialPlatform = "instagram" | "tiktok" | "facebook";

export interface SocialPost {
  platform: SocialPlatform;
  author: string | null;
  caption: string | null;
  /// Transient cover-image URL (signed, expires). Never persist.
  image: string | null;
}

const MOBILE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

export function socialPlatform(url: string): SocialPlatform | null {
  try {
    const host = new URL(url).hostname.toLowerCase();
    if (/(^|\.)instagram\.com$/.test(host)) return "instagram";
    if (/(^|\.)tiktok\.com$/.test(host)) return "tiktok";
    if (/(^|\.)(facebook\.com|fb\.com|fb\.watch)$/.test(host)) return "facebook";
    return null;
  } catch {
    return null;
  }
}

/// vm.tiktok.com/…, vt.tiktok.com/…, tiktok.com/t/… — the share-sheet
/// forms. oEmbed wants the canonical /@user/video/<id> URL.
export function isTikTokShortLink(url: string): boolean {
  try {
    const u = new URL(url);
    const host = u.hostname.toLowerCase();
    return host === "vm.tiktok.com" || host === "vt.tiktok.com" ||
      (/(^|\.)tiktok\.com$/.test(host) && /^\/t\//.test(u.pathname));
  } catch {
    return false;
  }
}

/// Follows redirects by hand (max 4 hops) and returns where a short link
/// lands, without downloading the destination page.
export async function resolveShortLink(url: string): Promise<string> {
  let current = url;
  for (let hop = 0; hop < 4; hop++) {
    try {
      const res = await fetch(current, {
        method: "HEAD",
        redirect: "manual",
        signal: AbortSignal.timeout(6_000),
        headers: { "User-Agent": MOBILE_UA },
      });
      const location = res.headers.get("location");
      if (!location || res.status < 300 || res.status >= 400) return current;
      current = new URL(location, current).toString();
    } catch {
      return current;
    }
  }
  return current;
}

/// Instagram's og:description reads
///   `3,886 likes, 22 comments - dezeen on July 3, 2026: "the caption…"`
/// and a profile page's reads `579 Followers, 63 Following, 18 Posts - …`.
/// Pull the author and the quoted caption out of the former; reject the
/// latter (a profile link names an account, not a post).
export function parseInstagramDescription(
  description: string,
): { author: string | null; caption: string } | null {
  const text = description.trim();
  if (/^\d[\d,.]*[KM]?\s+Followers,/i.test(text)) return null;
  const m = text.match(/^(?:.*?)\s-\s(\S+)\s+on\s+[A-Z][a-z]+\s+\d{1,2},\s+\d{4}:\s*["“]([\s\S]*)["”]\s*$/);
  if (m) return { author: m[1], caption: m[2].trim() };
  // Older/other shapes: keep the whole thing rather than lose the caption.
  return text ? { author: null, caption: text } : null;
}

function decodeEntities(s: string): string {
  return s
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)));
}

function metaContent(html: string, property: string): string | null {
  for (const tag of html.matchAll(/<meta\b[^>]*>/gi)) {
    const attrs = tag[0];
    const key = attrs.match(/(?:property|name)\s*=\s*["']([^"']+)["']/i)?.[1]?.toLowerCase();
    if (key !== property) continue;
    const content = attrs.match(/content\s*=\s*("([^"]*)"|'([^']*)')/i);
    const value = content?.[2] ?? content?.[3];
    if (value) return decodeEntities(value);
  }
  return null;
}

/// Strip a reel/tv/p link to its canonical post form; a profile or
/// explore link has no post and returns null.
export function instagramPostUrl(url: string): string | null {
  try {
    const u = new URL(url);
    const m = u.pathname.match(/^\/(?:[A-Za-z0-9_.]+\/)?(p|reel|reels|tv)\/([A-Za-z0-9_-]{5,})/);
    if (!m) return null;
    const kind = m[1] === "reels" ? "reel" : m[1];
    return `https://www.instagram.com/${kind}/${m[2]}/`;
  } catch {
    return null;
  }
}

async function fetchInstagram(url: string): Promise<SocialPost | null> {
  const postUrl = instagramPostUrl(url);
  if (!postUrl) return null;
  try {
    const res = await fetch(postUrl, {
      redirect: "follow",
      signal: AbortSignal.timeout(10_000),
      headers: { "User-Agent": MOBILE_UA, Accept: "text/html" },
    });
    if (!res.ok) return null;
    const html = (await res.text()).slice(0, 400_000);
    const description = metaContent(html, "og:description");
    const parsed = description ? parseInstagramDescription(description) : null;
    const image = metaContent(html, "og:image");
    // The login wall carries no og:description for the post and its
    // og:image is Instagram's own logo — nothing to work with.
    if (!parsed && !(image && /cdninstagram|fbcdn/.test(image))) return null;
    return {
      platform: "instagram",
      author: parsed?.author ?? null,
      caption: parsed?.caption ?? null,
      image: image && /cdninstagram|fbcdn/.test(image) ? image : null,
    };
  } catch {
    return null;
  }
}

async function fetchTikTok(url: string): Promise<SocialPost | null> {
  const canonical = isTikTokShortLink(url) ? await resolveShortLink(url) : url;
  try {
    const res = await fetch(
      `https://www.tiktok.com/oembed?url=${encodeURIComponent(canonical)}`,
      { signal: AbortSignal.timeout(8_000), headers: { "User-Agent": MOBILE_UA } },
    );
    if (!res.ok) return null;
    const data = await res.json() as {
      title?: string;
      author_name?: string;
      author_unique_id?: string;
      thumbnail_url?: string;
    };
    const caption = data.title?.trim() || null;
    const image = data.thumbnail_url ?? null;
    if (!caption && !image) return null;
    return {
      platform: "tiktok",
      author: data.author_unique_id ?? data.author_name ?? null,
      caption,
      image,
    };
  } catch {
    return null;
  }
}

/// Whatever the platform will tell us without a login — or null, meaning
/// the caller should fall back to the user's own words, a screenshot, or
/// asking.
export async function fetchSocialPost(url: string): Promise<SocialPost | null> {
  switch (socialPlatform(url)) {
    case "tiktok":
      return await fetchTikTok(url);
    case "instagram":
      return await fetchInstagram(url);
    default:
      return null;
  }
}

/// Download a (transient) cover image for the model to look at. Capped so a
/// giant original can't eat the worker's memory; null on any trouble.
export async function fetchImageBase64(
  url: string,
): Promise<{ base64: string; mediaType: string } | null> {
  try {
    const res = await fetch(url, {
      signal: AbortSignal.timeout(8_000),
      headers: { "User-Agent": MOBILE_UA },
    });
    if (!res.ok) return null;
    const type = res.headers.get("content-type")?.split(";")[0].trim() ?? "";
    if (!/^image\/(jpeg|png|webp|gif)$/.test(type)) return null;
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.length === 0 || bytes.length > 4_000_000) return null;
    let binary = "";
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
    }
    return { base64: btoa(binary), mediaType: type };
  } catch {
    return null;
  }
}

/// Thrown when a social link yields nothing at all and the user gave us
/// nothing else to go on — the app turns it into a question.
export class SocialUnreadableError extends Error {
  readonly platform: SocialPlatform;
  constructor(platform: SocialPlatform) {
    super(
      "Can't read this post. Add the place's name after the link, or share a screenshot of it instead.",
    );
    this.name = "SocialUnreadableError";
    this.platform = platform;
  }
}
