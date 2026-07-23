import { useMemo } from "react";
import { endOfWeek, format, isWithinInterval, parseISO, startOfWeek } from "date-fns";
import type { Item } from "@/lib/types";
import { daysUntilClose, daysUntilOpen, isActive, timeBucket } from "@/lib/api";
import { ItemCard } from "./ItemCard";

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

  const active = useMemo(() => items.filter(isActive), [items]);

  const plannedThisWeek = active
    .filter(
      (i) =>
        i.planned_for &&
        isWithinInterval(parseISO(i.planned_for), { start: weekStart, end: weekEnd }),
    )
    .sort((a, b) => a.planned_for!.localeCompare(b.planned_for!));

  const lastChance = active
    .filter((i) => timeBucket(i, now) === "last-chance")
    .sort((a, b) => (daysUntilClose(a, now) ?? 99) - (daysUntilClose(b, now) ?? 99));

  const closingSoon = active
    .filter((i) => timeBucket(i, now) === "closing-soon")
    .sort((a, b) => (daysUntilClose(a, now) ?? 99) - (daysUntilClose(b, now) ?? 99));

  const openingThisWeek = active
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

  return (
    <div className="space-y-6">
      <p className="text-sm text-muted-foreground">
        {format(weekStart, "d MMM")} – {format(weekEnd, "d MMM")}
      </p>

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
          Nothing on the radar this week. Dump some links in the Add tab.
        </p>
      )}
    </div>
  );
}
