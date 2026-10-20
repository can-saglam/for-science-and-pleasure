// What a shared save carries, and its link. The card has the shape the
// parser answers with (snake_case, as ParseClient.Card reads it), so the
// app opens a shared save the way it opens a parsed one.

export const SITE = "https://wegocan.com";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

/// Ten characters from 57: about 58 bits, so links can't be walked.
export function shareToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return [...bytes].map((b) => ALPHABET[b % ALPHABET.length]).join("");
}

export interface SharedCard {
  kind: "event" | "place";
  title: string;
  summary: string | null;
  venue: string | null;
  area: string | null;
  address: string | null;
  category: string | null;
  price: string | null;
  starts_on: string | null;
  ends_on: string | null;
  url: string | null;
  image_url: string | null;
  color: string | null;
  lat: number | null;
  lng: number | null;
  place_id: string | null;
  showings: { date: string; time: string | null; note: string | null }[] | null;
  source: "shared";
}

const DAY = /^\d{4}-\d{2}-\d{2}$/;

function text(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function link(v: unknown): string | null {
  const t = text(v, 2000);
  if (!t) return null;
  try {
    const u = new URL(t);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch {
    return null;
  }
}

const day = (v: unknown) => typeof v === "string" && DAY.test(v) ? v : null;
const coord = (v: unknown, limit: number) =>
  typeof v === "number" && Number.isFinite(v) && Math.abs(v) <= limit ? v : null;

/// The card as sent by the phone, kept to the public fields and their
/// sizes; null when it isn't one.
export function sharedCard(raw: unknown): SharedCard | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const title = text(r.title, 300);
  if (!title || (r.kind !== "event" && r.kind !== "place")) return null;
  const showings = Array.isArray(r.showings)
    ? r.showings.slice(0, 200).flatMap((s) => {
      const o = s as Record<string, unknown>;
      const date = day(o?.date);
      if (!date) return [];
      const time = typeof o.time === "string" && /^\d{2}:\d{2}$/.test(o.time) ? o.time : null;
      return [{ date, time, note: text(o.note, 80) }];
    })
    : [];
  const color = typeof r.color === "string" && /^#?[0-9a-fA-F]{6}$/.test(r.color) ? r.color : null;
  return {
    kind: r.kind,
    title,
    summary: text(r.summary, 1000),
    venue: text(r.venue, 300),
    area: text(r.area, 200),
    address: text(r.address, 500),
    category: text(r.category, 60),
    price: text(r.price, 200),
    starts_on: day(r.starts_on),
    ends_on: day(r.ends_on),
    url: link(r.url),
    image_url: link(r.image_url),
    color,
    lat: coord(r.lat, 90),
    lng: coord(r.lng, 180),
    place_id: text(r.place_id, 300),
    showings: showings.length ? showings : null,
    source: "shared",
  };
}
