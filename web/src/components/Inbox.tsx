import type { Item } from "@/lib/types";
import { ItemCard } from "./ItemCard";

export function Inbox({
  items,
  onSelect,
}: {
  items: Item[];
  onSelect: (item: Item) => void;
}) {
  const inbox = items.filter((i) => i.status === "inbox");
  if (inbox.length === 0) return null;
  return (
    <section className="space-y-2">
      <h3 className="font-heading text-base font-semibold">
        Inbox <span className="text-muted-foreground">({inbox.length})</span>
      </h3>
      <p className="text-xs text-muted-foreground">
        Freshly dumped — tap to check the details and confirm.
      </p>
      <div className="space-y-2">
        {inbox.map((i) => (
          <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
        ))}
      </div>
    </section>
  );
}
