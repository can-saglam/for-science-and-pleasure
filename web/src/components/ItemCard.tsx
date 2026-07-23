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
        <Badge className="bg-foreground text-background">
          {close === 0 ? "Last day" : `${close}d left`}
        </Badge>
      );
    case "closing-soon":
      return <Badge variant="outline">closes in {close}d</Badge>;
    case "upcoming":
      return <Badge variant="secondary">opens in {open}d</Badge>;
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
  return (
    <button
      onClick={onClick}
      className={cn(
        "w-full rounded-xl border bg-card px-4 py-3 text-left transition-colors hover:border-foreground/30 hover:bg-accent/50 active:bg-accent",
        item.status === "done" && "opacity-50",
      )}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate font-medium leading-snug">{item.title}</div>
          <div className="mt-0.5 truncate text-sm text-muted-foreground">
            {[item.venue, item.area].filter(Boolean).join(" · ") ||
              item.category ||
              (item.kind === "place" ? "place" : "event")}
          </div>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <TimeBadge item={item} />
          {item.status === "planned" && item.planned_for && (
            <Badge variant="secondary">
              {format(parseISO(item.planned_for), "EEE d MMM")}
            </Badge>
          )}
        </div>
      </div>
      {label && (
        <div className="mt-1 text-xs text-muted-foreground">{label}</div>
      )}
    </button>
  );
}
