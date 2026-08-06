import { differenceInCalendarDays, parseISO } from "date-fns";
import { supabase, SUPABASE_URL } from "./supabase";
import {
  ACTIVE_STATUSES,
  type DayPlan,
  type Item,
  type LocationProposal,
  type Member,
  type ParsedCard,
} from "./types";

export async function fetchItems(): Promise<Item[]> {
  const { data, error } = await supabase
    .from("items")
    .select("*")
    .is("deleted_at", null)
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data as Item[];
}

export async function insertItem(item: Partial<Item>): Promise<Item> {
  const { data: userData } = await supabase.auth.getUser();
  const { data, error } = await supabase
    .from("items")
    .insert({
      ...item,
      status: "saved",
      added_by_email: userData.user?.email ?? null,
    })
    .select()
    .single();
  if (error) throw error;
  return data as Item;
}

export async function updateItem(id: string, patch: Partial<Item>): Promise<Item> {
  const { data, error } = await supabase
    .from("items")
    .update(patch)
    .eq("id", id)
    .select()
    .single();
  if (error) throw error;
  return data as Item;
}

export async function softDeleteItem(id: string): Promise<void> {
  const { error } = await supabase
    .from("items")
    .update({ deleted_at: new Date().toISOString() })
    .eq("id", id);
  if (error) throw error;
}

export async function parseInput(input: {
  text?: string;
  image_base64?: string;
  image_media_type?: string;
}): Promise<ParsedCard> {
  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData.session?.access_token;
  const res = await fetch(`${SUPABASE_URL}/functions/v1/parse`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(input),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(json.error ?? `parse failed (${res.status})`);
  return json.card as ParsedCard;
}

export async function proposeLocations(items: Item[]): Promise<LocationProposal[]> {
  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData.session?.access_token;
  const res = await fetch(`${SUPABASE_URL}/functions/v1/locate`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      items: items.map((i) => ({
        id: i.id,
        kind: i.kind,
        title: i.title,
        summary: i.summary,
        venue: i.venue,
        area: i.area,
        address: i.address,
        url: i.url,
        notes: i.notes,
      })),
    }),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(json.error ?? `locate failed (${res.status})`);
  return json.proposals as LocationProposal[];
}

// Fire-and-forget: tell the other person about a confirmed save.
export function notifyPartnerOfSave(itemId: string): void {
  supabase.auth
    .getSession()
    .then(({ data }) => {
      const token = data.session?.access_token;
      if (!token) return;
      return fetch(`${SUPABASE_URL}/functions/v1/notify-save`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ item_id: itemId }),
      });
    })
    .catch(() => {});
}

export async function fetchMembers(): Promise<Member[]> {
  const { data, error } = await supabase.from("members").select("email, display_name");
  if (error) return [];
  return data as Member[];
}

export async function findByUrl(url: string): Promise<Item | null> {
  const { data } = await supabase
    .from("items")
    .select("*")
    .eq("url", url)
    .is("deleted_at", null)
    .limit(1)
    .maybeSingle();
  return (data as Item) ?? null;
}

export async function suggestPlans(date: string): Promise<DayPlan[]> {
  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData.session?.access_token;
  const res = await fetch(`${SUPABASE_URL}/functions/v1/suggest`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ date }),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(json.error ?? `suggest failed (${res.status})`);
  return (json.plans ?? []) as DayPlan[];
}

// ---- maps (Google Maps only, per house rules) -----------------------------

export function mapsQuery(item: Item): string {
  return [item.venue ?? item.title, item.area, "London"].filter(Boolean).join(", ");
}

export function googleMapsUrl(item: Item): string {
  if (item.lat && item.lng) {
    return `https://www.google.com/maps/search/?api=1&query=${item.lat},${item.lng}`;
  }
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(mapsQuery(item))}`;
}

export function googleDirectionsUrl(from: Item, to: Item): string {
  const enc = (i: Item) =>
    i.lat && i.lng ? `${i.lat},${i.lng}` : encodeURIComponent(mapsQuery(i));
  return `https://www.google.com/maps/dir/?api=1&origin=${enc(from)}&destination=${enc(to)}&travelmode=walking`;
}

export function haversineKm(
  a: { lat: number; lng: number },
  b: { lat: number; lng: number },
): number {
  const R = 6371;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((a.lat * Math.PI) / 180) *
      Math.cos((b.lat * Math.PI) / 180) *
      Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}

export function walkMinutes(km: number): number {
  return Math.max(1, Math.round(km * 12)); // ~5 km/h
}

// ---- time logic ----------------------------------------------------------

export function daysUntilClose(item: Item, today = new Date()): number | null {
  if (!item.ends_on) return null;
  return differenceInCalendarDays(parseISO(item.ends_on), today);
}

export function daysUntilOpen(item: Item, today = new Date()): number | null {
  if (!item.starts_on) return null;
  return differenceInCalendarDays(parseISO(item.starts_on), today);
}

export type TimeBucket =
  | "closing-soon"   // open now, ends within 21 days
  | "last-chance"    // ends within 7 days
  | "open-now"       // started, no imminent end
  | "upcoming"       // starts in the future
  | "past"           // ended
  | "anytime";       // place or undated

export function timeBucket(item: Item, today = new Date()): TimeBucket {
  if (item.kind === "place" || (!item.starts_on && !item.ends_on)) return "anytime";
  const open = daysUntilOpen(item, today);
  const close = daysUntilClose(item, today);
  if (close !== null && close < 0) return "past";
  if (open !== null && open > 0) return "upcoming";
  if (close !== null && close <= 7) return "last-chance";
  if (close !== null && close <= 21) return "closing-soon";
  return "open-now";
}

export function isActive(item: Item): boolean {
  return (ACTIVE_STATUSES as readonly string[]).includes(item.status);
}

// ---- ICS export ----------------------------------------------------------

export function downloadIcs(item: Item) {
  const date = item.starts_on;
  if (!date) return;
  const dt = date.replace(/-/g, "");
  const next = new Date(parseISO(date).getTime() + 86400000)
    .toISOString()
    .slice(0, 10)
    .replace(/-/g, "");
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Can We Go?//EN",
    "BEGIN:VEVENT",
    `UID:fsap-${item.id}`,
    `DTSTART;VALUE=DATE:${dt}`,
    `DTEND;VALUE=DATE:${next}`,
    `SUMMARY:${item.title.replace(/([,;\\])/g, "\\$1")}`,
    item.venue ? `LOCATION:${[item.venue, item.area].filter(Boolean).join(", ").replace(/([,;\\])/g, "\\$1")}` : "",
    item.url ? `URL:${item.url}` : "",
    "END:VEVENT",
    "END:VCALENDAR",
  ].filter(Boolean);
  const blob = new Blob([lines.join("\r\n")], { type: "text/calendar" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `${item.title.slice(0, 40)}.ics`;
  a.click();
  URL.revokeObjectURL(a.href);
}
