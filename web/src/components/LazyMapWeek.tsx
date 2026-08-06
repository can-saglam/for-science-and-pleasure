import { lazy, Suspense } from "react";
import { Loader2 } from "lucide-react";
import type { Item } from "@/lib/types";

// Leaflet is the heaviest dependency in the app; splitting it out keeps the
// initial bundle small — the chunk only loads when a map view is opened.
const MapWeek = lazy(() =>
  import("./MapWeek").then((m) => ({ default: m.MapWeek })),
);

export function LazyMapWeek(props: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  return (
    <Suspense
      fallback={
        <div className="flex h-[55dvh] items-center justify-center rounded-xl border md:h-[65dvh]">
          <Loader2 className="size-5 animate-spin text-muted-foreground" />
        </div>
      }
    >
      <MapWeek {...props} />
    </Suspense>
  );
}
