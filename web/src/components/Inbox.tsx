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
  return (
    <section className="space-y-2">
      <p className="text-xs text-muted-foreground">
        Freshly dumped — tap to check the details and confirm.
      </p>
      {inbox.length === 0 ? (
        <p className="pt-8 text-center text-sm text-muted-foreground">
          Inbox zero. Dump something with the + button.
        </p>
      ) : (
        <div className="grid gap-2 md:grid-cols-2">
          {inbox.map((i) => (
            <ItemCard key={i.id} item={i} onClick={() => onSelect(i)} />
          ))}
        </div>
      )}
    </section>
  );
}
