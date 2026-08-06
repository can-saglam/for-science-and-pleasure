import { daysUntilClose, daysUntilOpen, timeBucket } from "@/lib/api";
import { accentColor, cardTint } from "@/lib/colors";
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
      // One-day events don't "open" — they happen.
      return item.starts_on && item.starts_on === item.ends_on ? (
        <Badge variant="secondary">happening in {open}d</Badge>
      ) : (
        <Badge variant="secondary">opens in {open}d</Badge>
      );
    case "past":
      return <Badge variant="secondary" className="opacity-60">ended</Badge>;
    default:
      return null;
  }
}

export function ItemCard({
  item,
  onClick,
}: {
  item: Item;
  onClick?: () => void;
}) {
  const label = windowLabel(item);
  const { style, lightText } = cardTint(accentColor(item));
  const muted = lightText ? "text-white/75" : "text-muted-foreground";

  // Quiet nudges for incomplete saves — only on active items.
  const hints: string[] = [];
  if (item.status !== "done") {
    if (item.kind === "event" && !item.starts_on && !item.ends_on) {
      hints.push("needs a date");
    }
    if (item.lat == null || item.lng == null) hints.push("no location");
  }
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
      {(label || hints.length > 0) && (
        <div className="mt-1 flex flex-wrap gap-x-2 text-xs">
          {label && <span className={muted}>{label}</span>}
          {hints.map((h) => (
            <span
              key={h}
              className={
                lightText ? "text-amber-200" : "text-amber-600 dark:text-amber-500"
              }
            >
              {h}
            </span>
          ))}
        </div>
      )}
    </button>
  );
}
