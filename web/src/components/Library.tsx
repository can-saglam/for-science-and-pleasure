import { useMemo, useState } from "react";
import type { Item } from "@/lib/types";
import { daysUntilClose, isActive, timeBucket } from "@/lib/api";
import { ItemCard } from "./ItemCard";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

type Filter = "all" | "events" | "places" | "history";

function isMissed(i: Item): boolean {
  return isActive(i) && i.status !== "inbox" && timeBucket(i) === "past";
}

export function Library({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  const [filter, setFilter] = useState<Filter>("all");
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<string | null>(null);

  const base = useMemo(
    () => items.filter((i) => i.status !== "inbox"),
    [items],
  );

  const categories = useMemo(() => {
    const counts = new Map<string, number>();
    for (const i of base) {
      if (i.category) counts.set(i.category, (counts.get(i.category) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([c]) => c);
  }, [base]);

  const visible = useMemo(() => {
    let list = base;
    if (filter === "events") list = list.filter((i) => i.kind === "event" && isActive(i) && !isMissed(i));
    else if (filter === "places") list = list.filter((i) => i.kind === "place" && isActive(i));
    else if (filter === "history") list = list.filter((i) => i.status === "done" || isMissed(i));
    else list = list.filter((i) => isActive(i) && !isMissed(i));

    if (category) list = list.filter((i) => i.category === category);

    if (query.trim()) {
      const q = query.toLowerCase();
      list = list.filter((i) =>
        [i.title, i.venue, i.area, i.category, i.notes]
          .filter(Boolean)
          .some((f) => f!.toLowerCase().includes(q)),
      );
    }

    const rank = (i: Item) => {
      const b = timeBucket(i);
      if (b === "last-chance") return 0;
      if (b === "closing-soon") return 1;
      if (b === "past") return 3;
      return 2;
    };
    return list.sort((a, b) => {
      const r = rank(a) - rank(b);
      if (r !== 0) return r;
      const ca = daysUntilClose(a) ?? Infinity;
      const cb = daysUntilClose(b) ?? Infinity;
      if (ca !== cb) return ca - cb;
      return b.created_at.localeCompare(a.created_at);
    });
  }, [base, filter, query, category]);

  const done = visible.filter((i) => i.status === "done");
  const missed = visible.filter((i) => i.status !== "done");

  return (
    <div className="space-y-3">
      <Tabs value={filter} onValueChange={(v) => setFilter(v as Filter)}>
        <TabsList className="w-full">
          <TabsTrigger value="all" className="flex-1">All</TabsTrigger>
          <TabsTrigger value="events" className="flex-1">Events</TabsTrigger>
          <TabsTrigger value="places" className="flex-1">Places</TabsTrigger>
          <TabsTrigger value="history" className="flex-1">History</TabsTrigger>
        </TabsList>
      </Tabs>

      {categories.length > 1 && (
        <div className="flex gap-1.5 overflow-x-auto pb-1 [-ms-overflow-style:none] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {categories.map((c) => (
            <button
              key={c}
              onClick={() => setCategory(category === c ? null : c)}
              className={cn(
                "shrink-0 rounded-full border px-3 py-1 text-xs",
                category === c
                  ? "border-foreground bg-foreground text-background"
                  : "text-muted-foreground",
              )}
            >
              {c}
            </button>
          ))}
        </div>
      )}

      <Input
        placeholder="Search…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />

      {filter === "history" ? (
        <div className="space-y-4">
          {done.length > 0 && (
            <section className="space-y-2">
              <h3 className="text-sm font-medium text-muted-foreground">Done</h3>
              {done.map((i) => (
                <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
              ))}
            </section>
          )}
          {missed.length > 0 && (
            <section className="space-y-2">
              <h3 className="text-sm font-medium text-muted-foreground">
                Missed — ended before you made it
              </h3>
              {missed.map((i) => (
                <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
              ))}
            </section>
          )}
          {done.length + missed.length === 0 && (
            <p className="pt-8 text-center text-sm text-muted-foreground">
              No history yet. Go do something!
            </p>
          )}
        </div>
      ) : (
        <div className="space-y-2">
          {visible.length === 0 ? (
            <p className="pt-8 text-center text-sm text-muted-foreground">
              Nothing here yet.
            </p>
          ) : (
            visible.map((i) => (
              <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
            ))
          )}
        </div>
      )}
    </div>
  );
}
