import { addDays, format, subDays } from "date-fns";
import type { Item } from "./types";

const d = (offset: number) => format(addDays(new Date(), offset), "yyyy-MM-dd");
const past = (offset: number) => format(subDays(new Date(), offset), "yyyy-MM-dd");

function make(partial: Partial<Item>, i: number): Item {
  return {
    id: `demo-${i}`,
    kind: "event",
    status: "saved",
    title: "Untitled",
    summary: null,
    venue: null,
    area: null,
    address: null,
    category: null,
    price: null,
    url: null,
    booking_url: null,
    image_url: null,
    starts_on: null,
    ends_on: null,
    planned_for: null,
    notes: null,
    source: "manual",
    raw_input: null,
    added_by_email: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    deleted_at: null,
    ...partial,
  };
}

// Visible only with ?demo in the URL — never written to the database.
const seeds: Partial<Item>[] = [
  {
    title: "Yoshitomo Nara",
    venue: "Hayward Gallery",
    area: "South Bank",
    category: "exhibition",
    price: "£18",
    starts_on: past(40),
    ends_on: d(10),
  },
  {
    title: "Beryl Cook / Tom of Finland",
    venue: "Studio Voltaire",
    area: "Clapham",
    category: "exhibition",
    price: "Free",
    starts_on: past(80),
    ends_on: d(3),
  },
  {
    title: "Marina Abramović",
    venue: "Royal Academy",
    area: "Mayfair",
    category: "exhibition",
    price: "£25",
    starts_on: d(51),
    ends_on: d(160),
  },
  {
    title: "Frieze Sculpture",
    venue: "Regent's Park",
    area: "Regent's Park",
    category: "outdoors",
    price: "Free",
    starts_on: d(5),
    ends_on: d(30),
    status: "inbox",
  },
  {
    title: "Café Deco",
    kind: "place",
    venue: "Café Deco",
    area: "Bloomsbury",
    category: "cafe",
  },
  {
    title: "Brawn",
    kind: "place",
    venue: "Brawn",
    area: "Columbia Road",
    category: "food",
  },
  {
    title: "Columbia Road Flower Market",
    area: "Bethnal Green",
    category: "market",
    price: "Free",
    status: "planned",
    planned_for: d(3),
    starts_on: d(3),
    ends_on: d(3),
  },
];

export const DEMO_ITEMS: Item[] = seeds.map(make);
