import { useMemo, useState } from "react";
import {
  differenceInCalendarDays,
  endOfWeek,
  format,
  parseISO,
  startOfWeek,
} from "date-fns";
import type { Item } from "@/lib/types";
import {
  daysUntilClose,
  daysUntilOpen,
  isActive,
  timeBucket,
} from "@/lib/api";
import { ItemCard } from "./ItemCard";
import { LazyMapWeek } from "./LazyMapWeek";
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
    <section className="min-w-0 space-y-2">
      <div>
        <h3 className="font-heading text-base font-semibold">{title}</h3>
        {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      </div>
      <div className="min-w-0 space-y-2">
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

  // Everything else that's simply on — running with no imminent end, or
  // undated. Shown in full (no more weekly rotation): closing-soonest
  // first, endless ones oldest-saved first so early finds resurface.
  const onNow = active
    .filter(
      (i) =>
        i.kind === "event" &&
        ["open-now", "anytime"].includes(timeBucket(i, now)),
    )
    .sort((a, b) => {
      const ca = daysUntilClose(a, now);
      const cb = daysUntilClose(b, now);
      if (ca !== null && cb !== null) return ca - cb;
      if (ca !== null) return -1;
      if (cb !== null) return 1;
      return a.created_at.localeCompare(b.created_at);
    });

  // Resurface the oldest save that isn't already on screen this week.
  const shownIds = new Set(
    [...lastChance, ...closingSoon, ...openingThisWeek, ...onNow].map(
      (i) => i.id,
    ),
  );
  const stale = active
    .filter(
      (i) =>
        !shownIds.has(i.id) &&
        differenceInCalendarDays(now, parseISO(i.created_at)) > 60,
    )
    .sort((a, b) => a.created_at.localeCompare(b.created_at))
    .slice(0, 1);

  const empty =
    lastChance.length + closingSoon.length + openingThisWeek.length +
      onNow.length + stale.length ===
    0;

  // map = everything the week view talks about, plus every saved place
  const mapItems = useMemo(() => {
    const seen = new Set<string>();
    const out: Item[] = [];
    for (const i of [
      ...lastChance,
      ...closingSoon,
      ...openingThisWeek,
      ...onNow,
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
      <div className="sticky top-[calc(3.75rem+env(safe-area-inset-top)-1px)] z-20 -mx-4 flex transform-gpu items-center justify-between bg-background px-4 pb-2 will-change-transform md:top-[calc(4.5rem-1px)]">
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
        <LazyMapWeek items={mapItems} onSelect={onSelect} />
      ) : (
        <div className="grid min-w-0 grid-cols-1 gap-6 md:grid-cols-2 md:items-start">
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
        title="On now"
        hint="Everything else already running — no rush yet."
        items={onNow}
        onSelect={onSelect}
      />

      <Section
        title="Saved ages ago"
        hint="Been on the list a couple of months — still fancy it?"
        items={stale}
        onSelect={onSelect}
      />

      {empty && (
        <p className="pt-8 text-center text-sm text-muted-foreground md:col-span-2">
          Nothing on the radar this week. Dump something with the + button.
        </p>
      )}
        </div>
      )}
    </div>
  );
}
