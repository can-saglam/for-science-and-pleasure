import type { Item } from "@/lib/types";

function hexToRgb(hex: string): [number, number, number] | null {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

// When colour extraction came up empty (webp images, blocked pages, Google
// Maps saves), fall back to a curated palette so every card still gets a
// distinct, stable wash. Hashing the item id keeps it deterministic.
const PALETTE = [
  "#c65d3b", // terracotta
  "#c99a2e", // ochre
  "#7d8a3c", // olive
  "#3e7a52", // forest
  "#2e8a86", // teal
  "#3f7cae", // steel blue
  "#5561b3", // indigo
  "#8156a8", // violet
  "#a34d7e", // plum
  "#c04f5f", // rose
  "#b06a3a", // copper
  "#5c7288", // slate
];

function hashString(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) >>> 0;
  }
  return h;
}

export function accentColor(item: Item): string {
  return item.color ?? PALETTE[hashString(item.id) % PALETTE.length];
}

// Gentle wash of the item's source colour, blended toward the theme's card
// background: pastel on light, muted-deep on dark. If a tint ever comes out
// dark, the text flips to light so the card stays readable.
export function cardTint(color: string | null): {
  style?: React.CSSProperties;
  lightText: boolean;
} {
  const rgb = color ? hexToRgb(color) : null;
  if (!rgb) return { lightText: false };
  const dark =
    typeof document !== "undefined" &&
    document.documentElement.classList.contains("dark");
  // Light mode blends toward white; dark mode toward the dark card colour
  // (#171717, matching --card) with a stronger accent share so hues read.
  const base = dark ? 23 : 255;
  const blend = (weight: number) =>
    rgb.map((c) => Math.round(c * weight + base * (1 - weight)));
  const bg = blend(dark ? 0.3 : 0.16);
  const border = blend(dark ? 0.5 : 0.38);
  const luminance = (0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2]) / 255;
  return {
    style: {
      backgroundColor: `rgb(${bg.join(",")})`,
      borderColor: `rgb(${border.join(",")})`,
    },
    lightText: luminance < 0.55,
  };
}
