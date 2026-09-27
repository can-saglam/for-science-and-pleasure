// Fetching links someone else chose (a pasted URL, a page's og:image, a
// site the model named, a redirect) must never reach the server's own
// network: loopback, private ranges, link-local and cloud metadata. Every
// such fetch goes through `publicFetch`, which checks the address a name
// resolves to and follows redirects one hop at a time, checking each.

export class BlockedAddress extends Error {
  constructor(url: string) {
    super(`blocked non-public address: ${url}`);
    this.name = "BlockedAddress";
  }
}

const MAX_REDIRECTS = 6;

function v4Parts(ip: string): number[] | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  const nums = parts.map((p) => (/^\d{1,3}$/.test(p) ? Number(p) : NaN));
  return nums.every((n) => n >= 0 && n <= 255) ? nums : null;
}

function privateV4([a, b, c]: number[]): boolean {
  return a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && c === 0) ||
    (a === 192 && b === 0 && c === 2) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) ||
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113);
}

/// Loopback, private, link-local, shared, reserved or multicast — anything
/// that isn't the public internet. Unparseable counts as private.
export function isPrivateIp(raw: string): boolean {
  const ip = raw.replace(/^\[|\]$/g, "").toLowerCase();
  const v4 = v4Parts(ip);
  if (v4) return privateV4(v4);
  if (!ip.includes(":")) return true;
  // IPv4 embedded in IPv6: mapped (::ffff:a.b.c.d), NAT64, or written in hex.
  const tail = ip.match(/(\d{1,3}(?:\.\d{1,3}){3})$/)?.[1];
  if (tail) return privateV4(v4Parts(tail) ?? [0, 0, 0, 0]) || !/^(::ffff:|64:ff9b::)/.test(ip);
  const mapped = ip.match(/^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (mapped) {
    const hi = parseInt(mapped[1], 16);
    const lo = parseInt(mapped[2], 16);
    return privateV4([hi >> 8, hi & 255, lo >> 8, lo & 255]);
  }
  if (ip === "::" || ip === "::1") return true;
  const first = parseInt(ip.split(":")[0] || "0", 16);
  return (first & 0xfe00) === 0xfc00 || // fc00::/7 unique local
    (first & 0xffc0) === 0xfe80 || // fe80::/10 link-local
    (first & 0xff00) === 0xff00 || // multicast
    ip.startsWith("64:ff9b:") || ip.startsWith("2001:db8:") || ip.startsWith("::ffff:");
}

/// What can be checked without DNS: scheme, port, and a hostname that
/// could only be local.
export function isPublicUrl(raw: string): boolean {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (u.protocol !== "https:" && u.protocol !== "http:") return false;
  if (u.username || u.password) return false;
  if (u.port && u.port !== "80" && u.port !== "443") return false;
  const host = u.hostname.toLowerCase().replace(/\.$/, "");
  if (host.startsWith("[") || v4Parts(host)) return !isPrivateIp(host);
  if (!host.includes(".")) return false;
  return !/(^|\.)(localhost|local|internal|intranet|lan|home|corp|localdomain|home\.arpa|svc|cluster\.local)$/.test(host);
}

async function lookup(host: string, type: "A" | "AAAA"): Promise<string[] | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3_000);
  try {
    return await Deno.resolveDns(host, type, { signal: controller.signal });
  } catch (error) {
    // No records of this type is an answer; anything else (the runtime
    // not offering DNS, a timeout) is not knowing.
    return error instanceof Deno.errors.NotFound ? [] : null;
  } finally {
    clearTimeout(timer);
  }
}

/// Every address the name resolves to is public. When the runtime can't
/// resolve at all, the hostname checks above are what's left.
export async function resolvesPublic(raw: string): Promise<boolean> {
  if (!isPublicUrl(raw)) return false;
  const host = new URL(raw).hostname.toLowerCase().replace(/\.$/, "");
  if (host.startsWith("[") || v4Parts(host)) return true;
  const [a, aaaa] = await Promise.all([lookup(host, "A"), lookup(host, "AAAA")]);
  if (a === null && aaaa === null) return true;
  const addresses = [...(a ?? []), ...(aaaa ?? [])];
  return addresses.length > 0 && addresses.every((ip) => !isPrivateIp(ip));
}

/// `fetch` for links someone else chose. Redirects are followed by hand
/// (unless the caller asked for "manual"), each hop checked; a blocked
/// address throws `BlockedAddress`, which callers treat like any failure.
export async function publicFetch(url: string, init: RequestInit = {}): Promise<Response> {
  const manual = init.redirect === "manual";
  let current = url;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    if (!(await resolvesPublic(current))) throw new BlockedAddress(current);
    const res = await fetch(current, { ...init, redirect: "manual" });
    const location = res.headers.get("location");
    if (manual || res.status < 300 || res.status >= 400 || !location) {
      if (!manual && current !== url) {
        // Callers read `res.url` for where the link landed.
        Object.defineProperty(res, "url", { value: current });
      }
      return res;
    }
    await res.body?.cancel();
    current = new URL(location, current).toString();
  }
  throw new Error(`too many redirects: ${url}`);
}
