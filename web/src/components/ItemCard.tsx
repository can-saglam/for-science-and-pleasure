import { daysUntilClose, daysUntilOpen, timeBucket } from "@/lib/api";
import type { Item } from "@/lib/types";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { format, parseISO } from "date-fns";

export function windowLabel(item: Item): string | null {
  if (item.kind === "place") return null;
  const f = (d: string) => format(parseISO(d), "d MMM");
  if (item.starts_on && item.ends_on) {
    if (item.starts_on === item.ends_on) return f(item.starts_on);
    return `${f(item.starts_on)} – ${f(item.ends_on)}`;
  }
  if (item.ends_on) return `until ${f(item.ends_on)}`;
  if (item.starts_on) return `from ${f(item.starts_on)}`;
  return null;
}

export function TimeBadge({ item }: { item: Item }) {
  const bucket = timeBucket(item);
  const close = daysUntilClose(item);
  const open = daysUntilOpen(item);
  switch (bucket) {
    case "last-chance":
      return (
        <Badge
          className={cn(
            "bg-foreground text-background",
            close !== null && close <= 2 && "bg-destructive text-white",
          )}
        >
          {close === 0 ? "Last day" : `${close}d left`}
        </Badge>
      );
    case "closing-soon":
      return <Badge variant="outline">closes in {close}d</Badge>;
    case "open-now":
      return <Badge variant="secondary">on now</Badge>;
    case "upcoming":
      return <Badge variant="secondary">opens in {open}d</Badge>;
    case "past":
      return <Badge variant="secondary" className="opacity-60">ended</Badge>;
    default:
      return null;
  }
}

function hexToRgb(hex: string): [number, number, number] | null {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

// Gentle pastel wash of the item's source colour. If a tint ever comes out
// dark, the text flips to light so the card stays readable.
// Also used by the calendar to tint event bars consistently with the cards.
export function cardTint(color: string | null): {
  style?: React.CSSProperties;
  lightText: boolean;
} {
  const rgb = color ? hexToRgb(color) : null;
  if (!rgb) return { lightText: false };
  const blend = (weight: number) =>
    rgb.map((c) => Math.round(c * weight + 255 * (1 - weight)));
  const bg = blend(0.16);
  const border = blend(0.38);
  const luminance = (0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2]) / 255;
  return {
    style: {
      backgroundColor: `rgb(${bg.join(",")})`,
      borderColor: `rgb(${border.join(",")})`,
    },
    lightText: luminance < 0.55,
  };
}

export function ItemCard({
  item,
  onClick,
}: {
  item: Item;
  onClick?: () => void;
}) {
  const label = windowLabel(item);
  const { style, lightText } = cardTint(item.color);
  const muted = lightText ? "text-white/75" : "text-muted-foreground";
  return (
    <button
      onClick={onClick}
      style={style}
      className={cn(
        "box-border w-full min-w-0 max-w-full overflow-hidden rounded-xl border bg-card px-4 py-3 text-left transition-[filter] hover:brightness-[0.97] active:brightness-95",
        lightText && "text-white",
        item.status === "done" && "opacity-50",
      )}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate font-medium leading-snug">{item.title}</div>
          <div className={cn("mt-0.5 truncate text-sm", muted)}>
            {[item.venue, item.area].filter(Boolean).join(" · ") ||
              item.category ||
              (item.kind === "place" ? "place" : "event")}
          </div>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <TimeBadge item={item} />
        </div>
      </div>
      {label && <div className={cn("mt-1 text-xs", muted)}>{label}</div>}
    </button>
  );
}
