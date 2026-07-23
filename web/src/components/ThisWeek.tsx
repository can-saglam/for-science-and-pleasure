import { useMemo, useState } from "react";
import { endOfWeek, format, isWithinInterval, parseISO, startOfWeek } from "date-fns";
import type { Item } from "@/lib/types";
import { daysUntilClose, daysUntilOpen, isActive, timeBucket } from "@/lib/api";
import { ItemCard } from "./ItemCard";
import { MapWeek } from "./MapWeek";
import { cn } from "@/lib/utils";
import { List, Map as MapIcon } from "lucide-react";

function Section({
  title,
  hint,
  items,
  onSelect,
}: {
  title: string;
  hint?: string;
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  if (items.length === 0) return null;
  return (
    <section className="space-y-2">
      <div>
        <h3 className="font-heading text-base font-semibold">{title}</h3>
        {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      </div>
      <div className="space-y-2">
        {items.map((i) => (
          <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
        ))}
      </div>
    </section>
  );
}

export function ThisWeek({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  const now = new Date();
  const weekStart = startOfWeek(now, { weekStartsOn: 1 });
  const weekEnd = endOfWeek(now, { weekStartsOn: 1 });
  const [view, setView] = useState<"list" | "map">("list");

  const active = useMemo(() => items.filter(isActive), [items]);
  // planned items live in their own section only
  const unplanned = useMemo(
    () => active.filter((i) => i.status !== "planned"),
    [active],
  );

  const plannedThisWeek = active
    .filter(
      (i) =>
        i.planned_for &&
        isWithinInterval(parseISO(i.planned_for), { start: weekStart, end: weekEnd }),
    )
    .sort((a, b) => a.planned_for!.localeCompare(b.planned_for!));

  const lastChance = unplanned
    .filter((i) => timeBucket(i, now) === "last-chance")
    .sort((a, b) => (daysUntilClose(a, now) ?? 99) - (daysUntilClose(b, now) ?? 99));

  const closingSoon = unplanned
    .filter((i) => timeBucket(i, now) === "closing-soon")
    .sort((a, b) => (daysUntilClose(a, now) ?? 99) - (daysUntilClose(b, now) ?? 99));

  const openingThisWeek = unplanned
    .filter((i) => {
      const d = daysUntilOpen(i, now);
      return d !== null && d >= 0 && d <= 7;
    })
    .sort((a, b) => (daysUntilOpen(a, now) ?? 99) - (daysUntilOpen(b, now) ?? 99));

  const placeIdeas = useMemo(() => {
    const places = active.filter((i) => i.kind === "place" && i.status === "saved");
    // stable weekly rotation: seed by ISO week so the shortlist changes each week
    const seed = Number(format(now, "I")) + now.getFullYear();
    return [...places]
      .sort((a, b) => {
        const ha = (a.id.charCodeAt(0) * seed) % 97;
        const hb = (b.id.charCodeAt(0) * seed) % 97;
        return ha - hb;
      })
      .slice(0, 3);
  }, [active, now]);

  const empty =
    plannedThisWeek.length + lastChance.length + closingSoon.length +
    openingThisWeek.length + placeIdeas.length === 0;

  // map = everything the week view talks about, plus every saved place
  const mapItems = useMemo(() => {
    const seen = new Set<string>();
    const out: Item[] = [];
    for (const i of [
      ...plannedThisWeek,
      ...lastChance,
      ...closingSoon,
      ...openingThisWeek,
      ...active.filter((i) => i.kind === "place"),
    ]) {
      if (!seen.has(i.id)) {
        seen.add(i.id);
        out.push(i);
      }
    }
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <p className="text-sm text-muted-foreground">
          {format(weekStart, "d MMM")} – {format(weekEnd, "d MMM")}
        </p>
        <div className="flex rounded-lg border p-0.5">
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

      {view === "map" ? (
        <MapWeek items={mapItems} onSelect={onSelect} />
      ) : (
        <>
      <Section title="Planned" items={plannedThisWeek} onSelect={onSelect} />
      <Section
        title="Last chance"
        hint="Ending within a week — now or never."
        items={lastChance}
        onSelect={onSelect}
      />
      <Section
        title="Closing soon"
        hint="Ending within three weeks."
        items={closingSoon}
        onSelect={onSelect}
      />
      <Section
        title="Just opening"
        hint="Starting in the next seven days."
        items={openingThisWeek}
        onSelect={onSelect}
      />
      <Section
        title="Ideas from your list"
        hint="Saved places for a free evening — a fresh three each week."
        items={placeIdeas}
        onSelect={onSelect}
      />

      {empty && (
        <p className="pt-8 text-center text-sm text-muted-foreground">
          Nothing on the radar this week. Dump something with the + button.
        </p>
      )}
        </>
      )}
    </div>
  );
}
