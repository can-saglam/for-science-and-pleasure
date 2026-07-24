import { useMemo } from "react";
import { format, parseISO } from "date-fns";
import type { Item } from "@/lib/types";
import { isActive, timeBucket } from "@/lib/api";
import { ItemCard } from "./ItemCard";

export function WeDidGo({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  // updated_at is bumped by a DB trigger when an item is marked done,
  // so it doubles as "when we ticked it off" for the timeline.
  const months = useMemo(() => {
    const done = items
      .filter((i) => i.status === "done")
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    const groups = new Map<string, Item[]>();
    for (const i of done) {
      const key = format(parseISO(i.updated_at), "MMMM yyyy");
      groups.set(key, [...(groups.get(key) ?? []), i]);
    }
    return [...groups.entries()];
  }, [items]);

  const missed = useMemo(
    () =>
      items
        .filter((i) => isActive(i) && timeBucket(i) === "past")
        .sort((a, b) => (b.ends_on ?? "").localeCompare(a.ends_on ?? "")),
    [items],
  );

  const empty = months.length === 0 && missed.length === 0;

  return (
    <div className="space-y-6">
      <p className="text-sm text-muted-foreground">
        The outings you actually made it to.
      </p>

      {months.map(([month, list]) => (
        <section key={month} className="space-y-2">
          <h3 className="text-sm font-medium text-muted-foreground">{month}</h3>
          <div className="grid min-w-0 grid-cols-1 gap-2 md:grid-cols-2">
            {list.map((i) => (
              <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
            ))}
          </div>
        </section>
      ))}

      {missed.length > 0 && (
        <section className="space-y-2">
          <h3 className="text-sm font-medium text-muted-foreground">
            Missed — ended before you made it
          </h3>
          <div className="grid min-w-0 grid-cols-1 gap-2 md:grid-cols-2">
            {missed.map((i) => (
              <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
            ))}
          </div>
        </section>
      )}

      {empty && (
        <p className="pt-8 text-center text-sm text-muted-foreground">
          Nothing here yet. Go somewhere, then mark it done.
        </p>
      )}
    </div>
  );
}
