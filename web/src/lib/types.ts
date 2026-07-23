export type ItemKind = "event" | "place";
export type ItemStatus = "inbox" | "saved" | "planned" | "done" | "archived";

export interface Item {
  id: string;
  kind: ItemKind;
  status: ItemStatus;
  title: string;
  summary: string | null;
  venue: string | null;
  area: string | null;
  address: string | null;
  category: string | null;
  price: string | null;
  url: string | null;
  booking_url: string | null;
  image_url: string | null;
  starts_on: string | null; // YYYY-MM-DD
  ends_on: string | null;
  planned_for: string | null;
  lat: number | null;
  lng: number | null;
  notes: string | null;
  source: string;
  raw_input: string | null;
  added_by_email: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface ParsedCard {
  kind: ItemKind;
  title: string;
  summary: string | null;
  venue: string | null;
  area: string | null;
  address: string | null;
  category: string | null;
  price: string | null;
  booking_url: string | null;
  starts_on: string | null;
  ends_on: string | null;
  url: string | null;
  source: string;
  lat: number | null;
  lng: number | null;
}

export interface Member {
  email: string;
  display_name: string | null;
}

export interface DayPlan {
  title: string;
  why: string;
  item_ids: string[];
  steps: string[];
}

export const CATEGORIES = [
  "exhibition",
  "gig",
  "theatre",
  "film",
  "market",
  "festival",
  "food",
  "drink",
  "cafe",
  "talk",
  "workshop",
  "outdoors",
  "other",
] as const;
