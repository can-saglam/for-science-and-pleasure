import { useMemo, useState } from "react";
import type { Item } from "@/lib/types";
import { daysUntilClose, isActive, timeBucket } from "@/lib/api";
import { ItemCard } from "./ItemCard";
import { MapWeek } from "./MapWeek";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { List, Map as MapIcon } from "lucide-react";

type Filter = "all" | "events" | "places";
type View = "list" | "map";

function isMissed(i: Item): boolean {
  return isActive(i) && timeBucket(i) === "past";
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
  const [view, setView] = useState<View>("list");

  const base = useMemo(() => items, [items]);

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

  return (
    <div className="w-full min-w-0 space-y-3">
      <div className="sticky top-[calc(3.75rem+env(safe-area-inset-top)-1px)] z-20 -mx-4 transform-gpu space-y-3 bg-background px-4 pb-2 will-change-transform md:top-[calc(4.5rem-1px)]">
        <Tabs value={filter} onValueChange={(v) => setFilter(v as Filter)}>
          <TabsList className="w-full">
            <TabsTrigger value="all" className="flex-1">All</TabsTrigger>
            <TabsTrigger value="events" className="flex-1">Events</TabsTrigger>
            <TabsTrigger value="places" className="flex-1">Places</TabsTrigger>
          </TabsList>
        </Tabs>

        {categories.length > 1 && (
          <div className="flex w-full min-w-0 max-w-full gap-1.5 overflow-x-auto pb-1 [-ms-overflow-style:none] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
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

        <div className="flex w-full min-w-0 items-center gap-2">
          <Input
            placeholder="Search…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          <div className="flex shrink-0 rounded-lg border p-0.5">
            {(
              [
                { id: "list", icon: List, label: "List" },
                { id: "map", icon: MapIcon, label: "Map" },
              ] as const
            ).map(({ id, icon: Icon, label }) => (
              <button
                key={id}
                onClick={() => setView(id)}
                aria-label={label}
                className={cn(
                  "flex items-center gap-1 rounded-md px-2.5 py-1 text-xs",
                  view === id
                    ? "bg-foreground text-background"
                    : "text-muted-foreground",
                )}
              >
                <Icon className="size-3.5" /> {label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {view === "map" ? (
        <MapWeek items={visible} onSelect={onSelect} />
      ) : (
        <div className="grid min-w-0 grid-cols-1 gap-2 md:grid-cols-2">
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
