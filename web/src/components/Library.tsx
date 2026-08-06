import { useMemo, useState } from "react";
import type { Item, Member } from "@/lib/types";
import { daysUntilClose, isActive, timeBucket } from "@/lib/api";
import { ItemCard } from "./ItemCard";
import { LazyMapWeek } from "./LazyMapWeek";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { List, Map as MapIcon } from "lucide-react";

type View = "list" | "map";

function isMissed(i: Item): boolean {
  return isActive(i) && timeBucket(i) === "past";
}

// One saved-things browser, scoped by kind: the Library tab shows events,
// the Places tab shows places. Missed events live in We Did Go, not here.
export function Library({
  items,
  members,
  onSelect,
  kind,
}: {
  items: Item[];
  members: Member[];
  onSelect: (item: Item) => void;
  kind: "event" | "place";
}) {
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<string | null>(null);
  const [area, setArea] = useState<string | null>(null);
  const [who, setWho] = useState<string | null>(null);
  const [view, setView] = useState<View>("list");

  const base = useMemo(
    () =>
      items.filter(
        (i) => i.kind === kind && isActive(i) && !isMissed(i),
      ),
    [items, kind],
  );

  const categories = useMemo(() => {
    const counts = new Map<string, number>();
    for (const i of base) {
      if (i.category) counts.set(i.category, (counts.get(i.category) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([c]) => c);
  }, [base]);

  // Top neighbourhoods, keyed case-insensitively but shown as first saved.
  const areas = useMemo(() => {
    const counts = new Map<string, { label: string; n: number }>();
    for (const i of base) {
      const label = i.area?.trim();
      if (!label) continue;
      const key = label.toLowerCase();
      const entry = counts.get(key);
      counts.set(key, { label: entry?.label ?? label, n: (entry?.n ?? 0) + 1 });
    }
    return [...counts.entries()]
      .sort((a, b) => b[1].n - a[1].n)
      .slice(0, 8)
      .map(([key, { label }]) => ({ key, label }));
  }, [base]);

  const people = useMemo(
    () =>
      members.map((m) => ({
        email: m.email,
        label: m.display_name ?? m.email.split("@")[0],
      })),
    [members],
  );

  const visible = useMemo(() => {
    let list = base;
    if (category) list = list.filter((i) => i.category === category);
    if (area) list = list.filter((i) => i.area?.trim().toLowerCase() === area);
    if (who) list = list.filter((i) => i.added_by_email === who);

    if (query.trim()) {
      const q = query.toLowerCase();
      list = list.filter((i) =>
        [i.title, i.venue, i.area, i.category, i.notes]
          .filter(Boolean)
          .some((f) => f!.toLowerCase().includes(q)),
      );
    }

    // Chronological by closing date — soonest first; runs with no end date
    // (and places) fall to the bottom, newest saves first there.
    return list.sort((a, b) => {
      const ca = daysUntilClose(a) ?? Infinity;
      const cb = daysUntilClose(b) ?? Infinity;
      if (ca !== cb) return ca - cb;
      return b.created_at.localeCompare(a.created_at);
    });
  }, [base, query, category, area, who]);

  return (
    <div className="w-full min-w-0 space-y-3">
      <div className="sticky top-[calc(3.75rem+env(safe-area-inset-top)-1px)] z-20 -mx-4 transform-gpu space-y-3 bg-background px-4 pb-2 will-change-transform md:top-[calc(4.5rem-1px)]">
        {(people.length > 1 || categories.length > 1 || areas.length > 1) && (
          <div className="flex w-full min-w-0 max-w-full items-center gap-1.5 overflow-x-auto pb-1 [-ms-overflow-style:none] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
            {people.length > 1 &&
              people.map((p) => (
                <button
                  key={p.email}
                  onClick={() => setWho(who === p.email ? null : p.email)}
                  className={cn(
                    "shrink-0 rounded-full border px-3 py-1 text-xs",
                    who === p.email
                      ? "border-foreground bg-foreground text-background"
                      : "text-muted-foreground",
                  )}
                >
                  {p.label}
                </button>
              ))}
            {people.length > 1 && categories.length > 1 && (
              <span className="h-4 w-px shrink-0 bg-border" />
            )}
            {categories.length > 1 &&
              categories.map((c) => (
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
            {areas.length > 1 && (categories.length > 1 || people.length > 1) && (
              <span className="h-4 w-px shrink-0 bg-border" />
            )}
            {areas.length > 1 &&
              areas.map((a) => (
                <button
                  key={a.key}
                  onClick={() => setArea(area === a.key ? null : a.key)}
                  className={cn(
                    "shrink-0 rounded-full border px-3 py-1 text-xs",
                    area === a.key
                      ? "border-foreground bg-foreground text-background"
                      : "text-muted-foreground",
                  )}
                >
                  {a.label}
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
        <LazyMapWeek items={visible} onSelect={onSelect} />
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
