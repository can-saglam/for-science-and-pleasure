import { useMemo, useState } from "react";
import type { Item } from "@/lib/types";
import { daysUntilClose, isActive, timeBucket } from "@/lib/api";
import { ItemCard } from "./ItemCard";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Input } from "@/components/ui/input";

type Filter = "all" | "events" | "places" | "done";

export function Library({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  const [filter, setFilter] = useState<Filter>("all");
  const [query, setQuery] = useState("");

  const visible = useMemo(() => {
    let list = items.filter((i) => i.status !== "inbox");
    if (filter === "events") list = list.filter((i) => i.kind === "event" && isActive(i));
    else if (filter === "places") list = list.filter((i) => i.kind === "place" && isActive(i));
    else if (filter === "done") list = list.filter((i) => i.status === "done");
    else list = list.filter(isActive);

    if (query.trim()) {
      const q = query.toLowerCase();
      list = list.filter((i) =>
        [i.title, i.venue, i.area, i.category, i.notes]
          .filter(Boolean)
          .some((f) => f!.toLowerCase().includes(q)),
      );
    }

    // urgency first: last-chance, closing-soon, then the rest by recency
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
  }, [items, filter, query]);

  return (
    <div className="space-y-3">
      <Tabs value={filter} onValueChange={(v) => setFilter(v as Filter)}>
        <TabsList className="w-full">
          <TabsTrigger value="all" className="flex-1">All</TabsTrigger>
          <TabsTrigger value="events" className="flex-1">Events</TabsTrigger>
          <TabsTrigger value="places" className="flex-1">Places</TabsTrigger>
          <TabsTrigger value="done" className="flex-1">Done</TabsTrigger>
        </TabsList>
      </Tabs>
      <Input
        placeholder="Search…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
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
    </div>
  );
}
