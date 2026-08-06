import { useMemo } from "react";
import { format, startOfWeek } from "date-fns";
import { daysUntilClose, daysUntilOpen, isActive, timeBucket } from "@/lib/api";
import type { Item } from "@/lib/types";
import { ItemCard } from "@/components/ItemCard";
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from "@/components/ui/drawer";

function Section({
  title,
  items,
  onSelect,
}: {
  title: string;
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  if (items.length === 0) return null;
  return (
    <section className="min-w-0 space-y-2">
      <h3 className="font-heading text-base font-semibold">{title}</h3>
      <div className="min-w-0 space-y-2">
        {items.map((i) => (
          <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
        ))}
      </div>
    </section>
  );
}

// A factual summary of the week, computed live from the saved items —
// the same date rules as the This Week tab, no stored or generated text.
export function DigestSheet({
  open,
  items,
  onSelect,
  onClose,
}: {
  open: boolean;
  items: Item[];
  onSelect: (item: Item) => void;
  onClose: () => void;
}) {
  const now = new Date();

  const { lastChance, thisWeek, opening, activeCount, undatedCount } =
    useMemo(() => {
      const active = items.filter(isActive);
      const events = active.filter((i) => i.kind === "event");

      // One-day events get their own section below, even when today.
      const lastChance = events
        .filter(
          (i) =>
            timeBucket(i, now) === "last-chance" &&
            !(i.starts_on && i.starts_on === i.ends_on),
        )
        .sort(
          (a, b) =>
            (daysUntilClose(a, now) ?? 99) - (daysUntilClose(b, now) ?? 99),
        );

      // One-day events happening within the next 7 days.
      const thisWeek = events
        .filter((i) => {
          if (!i.starts_on || i.starts_on !== i.ends_on) return false;
          const d = daysUntilOpen(i, now);
          return d !== null && d >= 0 && d <= 7;
        })
        .sort(
          (a, b) =>
            (daysUntilOpen(a, now) ?? 99) - (daysUntilOpen(b, now) ?? 99),
        );
      const shown = new Set([...lastChance, ...thisWeek].map((i) => i.id));

      const opening = events
        .filter((i) => {
          if (shown.has(i.id)) return false;
          const d = daysUntilOpen(i, now);
          return d !== null && d > 0 && d <= 7;
        })
        .sort(
          (a, b) =>
            (daysUntilOpen(a, now) ?? 99) - (daysUntilOpen(b, now) ?? 99),
        );

      return {
        lastChance,
        thisWeek,
        opening,
        activeCount: active.length,
        undatedCount: events.filter((i) => !i.starts_on && !i.ends_on).length,
      };
    }, [items, open]); // eslint-disable-line react-hooks/exhaustive-deps

  const empty =
    lastChance.length + thisWeek.length + opening.length === 0;
  const weekStart = startOfWeek(now, { weekStartsOn: 1 });

  return (
    <Drawer open={open} onOpenChange={(o) => !o && onClose()}>
      <DrawerContent className="max-h-[92dvh]">
        <div className="mx-auto w-full max-w-lg space-y-5 overflow-y-auto px-4 pb-8">
          <DrawerHeader className="px-0 pb-0 text-left">
            <DrawerTitle>This week</DrawerTitle>
            <DrawerDescription>
              Week of {format(weekStart, "d MMMM")}
            </DrawerDescription>
          </DrawerHeader>

          {empty ? (
            <p className="text-sm text-muted-foreground">
              Nothing pressing this week — no closings, one-offs, or openings
              among your saves.
            </p>
          ) : (
            <>
              <Section
                title="Last chance"
                items={lastChance}
                onSelect={onSelect}
              />
              <Section
                title="Happening this week"
                items={thisWeek}
                onSelect={onSelect}
              />
              <Section title="Just opening" items={opening} onSelect={onSelect} />
            </>
          )}

          <p className="text-xs text-muted-foreground">
            {activeCount} active save{activeCount === 1 ? "" : "s"}
            {undatedCount > 0 && ` · ${undatedCount} without dates`}
          </p>
        </div>
      </DrawerContent>
    </Drawer>
  );
}
