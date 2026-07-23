import { differenceInCalendarDays, parseISO } from "date-fns";
import { supabase, SUPABASE_URL } from "./supabase";
import type { Item, ParsedCard } from "./types";

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
    .insert({ ...item, added_by_email: userData.user?.email ?? null })
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
  return item.status === "saved" || item.status === "planned" || item.status === "inbox";
}

// ---- ICS export ----------------------------------------------------------

export function downloadIcs(item: Item) {
  const date = item.planned_for ?? item.starts_on;
  if (!date) return;
  const dt = date.replace(/-/g, "");
  const next = new Date(parseISO(date).getTime() + 86400000)
    .toISOString()
    .slice(0, 10)
    .replace(/-/g, "");
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//For Science and Pleasure//EN",
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
