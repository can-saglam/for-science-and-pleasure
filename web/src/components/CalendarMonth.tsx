import { useMemo, useState } from "react";
import {
  addDays,
  addMonths,
  eachWeekOfInterval,
  endOfMonth,
  endOfWeek,
  format,
  isSameDay,
  isSameMonth,
  isToday,
  isWithinInterval,
  max as maxDate,
  min as minDate,
  parseISO,
  startOfMonth,
  startOfWeek,
} from "date-fns";
import type { Item } from "@/lib/types";
import { isActive } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { ItemCard } from "./ItemCard";
import { cn } from "@/lib/utils";
import { ChevronLeft, ChevronRight } from "lucide-react";

const MAX_LANES = 3;

interface Bar {
  item: Item;
  colStart: number; // 1-7
  colEnd: number;   // exclusive end 2-8
  lane: number;
  openStart: boolean; // window continues before this week
  openEnd: boolean;   // window continues after this week
}

function weekBars(items: Item[], weekStart: Date): { bars: Bar[]; overflow: number } {
  const weekEnd = endOfWeek(weekStart, { weekStartsOn: 1 });
  const windows = items
    .filter(
      (i) =>
        i.kind === "event" &&
        isActive(i) &&
        (i.starts_on || i.ends_on),
    )
    .map((i) => {
      const s = i.starts_on ? parseISO(i.starts_on) : parseISO(i.ends_on!);
      const e = i.ends_on ? parseISO(i.ends_on) : parseISO(i.starts_on!);
      return { item: i, s, e };
    })
    .filter(({ s, e }) => s <= weekEnd && e >= weekStart)
    .sort((a, b) => a.s.getTime() - b.s.getTime() || b.e.getTime() - a.e.getTime());

  const laneEnds: Date[] = [];
  const bars: Bar[] = [];
  let overflow = 0;
  for (const { item, s, e } of windows) {
    const segStart = maxDate([s, weekStart]);
    const segEnd = minDate([e, weekEnd]);
    let lane = laneEnds.findIndex((end) => end < segStart);
    if (lane === -1) {
      if (laneEnds.length >= MAX_LANES) {
        overflow++;
        continue;
      }
      lane = laneEnds.length;
      laneEnds.push(segEnd);
    } else {
      laneEnds[lane] = segEnd;
    }
    const colStart = Math.round((segStart.getTime() - weekStart.getTime()) / 86400000) + 1;
    const colEnd = Math.round((segEnd.getTime() - weekStart.getTime()) / 86400000) + 2;
    bars.push({
      item,
      colStart,
      colEnd,
      lane,
      openStart: s < weekStart,
      openEnd: e > weekEnd,
    });
  }
  return { bars, overflow };
}

export function CalendarMonth({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  const [month, setMonth] = useState(() => startOfMonth(new Date()));
  const [selectedDay, setSelectedDay] = useState<Date | null>(null);

  const weeks = useMemo(
    () =>
      eachWeekOfInterval(
        { start: startOfWeek(startOfMonth(month), { weekStartsOn: 1 }), end: endOfMonth(month) },
        { weekStartsOn: 1 },
      ),
    [month],
  );

  const planned = items.filter((i) => i.status === "planned" && i.planned_for);

  const dayItems = useMemo(() => {
    if (!selectedDay) return [];
    return items.filter((i) => {
      if (!isActive(i)) return false;
      if (i.planned_for && isSameDay(parseISO(i.planned_for), selectedDay)) return true;
      if (i.kind === "event" && i.starts_on && i.ends_on) {
        return isWithinInterval(selectedDay, {
          start: parseISO(i.starts_on),
          end: parseISO(i.ends_on),
        });
      }
      if (i.kind === "event" && i.starts_on) return isSameDay(parseISO(i.starts_on), selectedDay);
      return false;
    });
  }, [items, selectedDay]);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="font-heading text-lg font-semibold">
          {format(month, "MMMM yyyy")}
        </h2>
        <div className="flex gap-1">
          <Button variant="ghost" size="icon" onClick={() => setMonth(addMonths(month, -1))}>
            <ChevronLeft />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setMonth(startOfMonth(new Date()))}
          >
            Today
          </Button>
          <Button variant="ghost" size="icon" onClick={() => setMonth(addMonths(month, 1))}>
            <ChevronRight />
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-7 text-center text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        {["M", "T", "W", "T", "F", "S", "S"].map((d, i) => (
          <div key={i}>{d}</div>
        ))}
      </div>

      <div className="space-y-1">
        {weeks.map((weekStart) => {
          const { bars, overflow } = weekBars(items, weekStart);
          return (
            <div
              key={weekStart.toISOString()}
              className="grid grid-cols-7 gap-y-0.5 border-t pt-1"
            >
              {Array.from({ length: 7 }).map((_, i) => {
                const day = addDays(weekStart, i);
                const hasPlan = planned.some((p) =>
                  isSameDay(parseISO(p.planned_for!), day),
                );
                return (
                  <button
                    key={i}
                    onClick={() => setSelectedDay(day)}
                    className={cn(
                      "mx-auto flex size-8 flex-col items-center justify-center rounded-full text-sm",
                      !isSameMonth(day, month) && "text-muted-foreground/40",
                      isToday(day) && "bg-foreground font-semibold text-background",
                      selectedDay && isSameDay(day, selectedDay) && !isToday(day) && "bg-accent",
                    )}
                  >
                    {format(day, "d")}
                    <span
                      className={cn(
                        "size-1 rounded-full",
                        hasPlan ? (isToday(day) ? "bg-background" : "bg-foreground") : "bg-transparent",
                      )}
                    />
                  </button>
                );
              })}
              {bars.map((bar) => (
                <button
                  key={bar.item.id + bar.colStart}
                  onClick={() => onSelect(bar.item)}
                  style={{ gridColumn: `${bar.colStart} / ${bar.colEnd}`, gridRow: bar.lane + 2 }}
                  className={cn(
                    "h-5 truncate border border-foreground/25 bg-secondary px-1.5 text-left text-[10px] leading-5",
                    bar.openStart ? "rounded-l-none border-l-0" : "rounded-l-md",
                    bar.openEnd ? "rounded-r-none border-r-0" : "rounded-r-md",
                  )}
                >
                  {bar.item.title}
                </button>
              ))}
              {overflow > 0 && (
                <div
                  style={{ gridColumn: "1 / 8", gridRow: MAX_LANES + 2 }}
                  className="px-1 text-[10px] text-muted-foreground"
                >
                  +{overflow} more
                </div>
              )}
            </div>
          );
        })}
      </div>

      {selectedDay && (
        <div className="space-y-2">
          <h3 className="text-sm font-medium text-muted-foreground">
            {format(selectedDay, "EEEE d MMMM")}
          </h3>
          {dayItems.length === 0 ? (
            <p className="text-sm text-muted-foreground">Nothing on this day.</p>
          ) : (
            dayItems.map((i) => (
              <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
            ))
          )}
        </div>
      )}
    </div>
  );
}
