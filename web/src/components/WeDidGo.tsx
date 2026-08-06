import { useMemo, useState } from "react";
import { format, parseISO } from "date-fns";
import type { Item } from "@/lib/types";
import { isActive, timeBucket } from "@/lib/api";
import { accentColor } from "@/lib/colors";
import { cn } from "@/lib/utils";

type Side = "been" | "missed";

function groupByMonth(
  list: Item[],
  dateOf: (i: Item) => string,
): [string, Item[]][] {
  const groups = new Map<string, Item[]>();
  for (const i of list) {
    const key = format(parseISO(dateOf(i)), "MMMM yyyy");
    groups.set(key, [...(groups.get(key) ?? []), i]);
  }
  return [...groups.entries()];
}

// Slim journal row — this tab is a log, not a second Library, so no big
// tinted cards: just an accent dot, the essentials, and the relevant date.
function LogRow({
  item,
  date,
  onClick,
}: {
  item: Item;
  date: string;
  onClick: () => void;
}) {
  const sub = [item.venue, item.area].filter(Boolean).join(" · ");
  return (
    <button
      onClick={onClick}
      className="flex w-full min-w-0 items-center gap-3 rounded-lg border bg-card px-3 py-2.5 text-left transition-colors active:bg-accent"
    >
      <span
        className="size-2.5 shrink-0 rounded-full"
        style={{ backgroundColor: accentColor(item) }}
      />
      <span className="min-w-0 flex-1">
        <span className="block truncate font-medium leading-snug">
          {item.title}
        </span>
        {sub && (
          <span className="block truncate text-sm text-muted-foreground">
            {sub}
          </span>
        )}
      </span>
      <span className="shrink-0 text-xs text-muted-foreground">{date}</span>
    </button>
  );
}

export function WeDidGo({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  const [side, setSide] = useState<Side>("been");

  // updated_at is bumped by a DB trigger when an item is marked done,
  // so it doubles as "when we ticked it off" for the timeline.
  const been = useMemo(() => {
    const done = items
      .filter((i) => i.status === "done")
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    return groupByMonth(done, (i) => i.updated_at);
  }, [items]);

  const missed = useMemo(() => {
    const past = items
      .filter((i) => isActive(i) && timeBucket(i) === "past" && i.ends_on)
      .sort((a, b) => b.ends_on!.localeCompare(a.ends_on!));
    return groupByMonth(past, (i) => i.ends_on!);
  }, [items]);

  const beenCount = been.reduce((n, [, list]) => n + list.length, 0);
  const missedCount = missed.reduce((n, [, list]) => n + list.length, 0);
  const months = side === "been" ? been : missed;

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-1 rounded-lg border p-1">
        {(
          [
            { id: "been", label: `Been${beenCount ? ` · ${beenCount}` : ""}` },
            {
              id: "missed",
              label: `Missed${missedCount ? ` · ${missedCount}` : ""}`,
            },
          ] as const
        ).map(({ id, label }) => (
          <button
            key={id}
            onClick={() => setSide(id)}
            className={cn(
              "min-h-9 rounded-md text-sm",
              side === id
                ? "bg-foreground font-medium text-background"
                : "text-muted-foreground",
            )}
          >
            {label}
          </button>
        ))}
      </div>

      {months.map(([month, list]) => (
        <section key={month} className="space-y-2">
          <h3 className="text-sm font-medium text-muted-foreground">
            {month} · {list.length}
          </h3>
          <div className="grid min-w-0 grid-cols-1 gap-1.5 md:grid-cols-2">
            {list.map((i) => (
              <LogRow
                key={i.id}
                item={i}
                date={
                  side === "been"
                    ? `went ${format(parseISO(i.updated_at), "d MMM")}`
                    : `ended ${format(parseISO(i.ends_on!), "d MMM")}`
                }
                onClick={() => onSelect(i)}
              />
            ))}
          </div>
        </section>
      ))}

      {months.length === 0 && (
        <p className="pt-8 text-center text-sm text-muted-foreground">
          {side === "been"
            ? "Nothing here yet. Go somewhere, then mark it done."
            : "Nothing missed — you're keeping up."}
        </p>
      )}
    </div>
  );
}
