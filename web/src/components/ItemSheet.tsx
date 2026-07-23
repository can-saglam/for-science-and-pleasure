import { useEffect, useState } from "react";
import { downloadIcs, softDeleteItem, updateItem } from "@/lib/api";
import type { Item, ItemKind } from "@/lib/types";
import { CATEGORIES } from "@/lib/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  Drawer,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
} from "@/components/ui/drawer";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { toast } from "sonner";
import { ArrowUpRight, CalendarPlus, Check, Trash2, Undo2 } from "lucide-react";

export function ItemSheet({
  item,
  onClose,
  onChanged,
}: {
  item: Item | null;
  onClose: () => void;
  onChanged: () => void;
}) {
  const [draft, setDraft] = useState<Item | null>(item);
  useEffect(() => setDraft(item), [item]);

  if (!draft) return <Drawer open={false} />;

  const set = (patch: Partial<Item>) => setDraft({ ...draft, ...patch });

  async function save(extra: Partial<Item> = {}) {
    if (!draft) return;
    try {
      await updateItem(draft.id, {
        kind: draft.kind,
        title: draft.title,
        summary: draft.summary,
        venue: draft.venue,
        area: draft.area,
        category: draft.category,
        price: draft.price,
        url: draft.url,
        starts_on: draft.starts_on || null,
        ends_on: draft.ends_on || null,
        planned_for: draft.planned_for || null,
        notes: draft.notes,
        ...extra,
      });
      onChanged();
      onClose();
    } catch (e) {
      toast.error(String(e));
    }
  }

  return (
    <Drawer open={!!item} onOpenChange={(open) => !open && onClose()}>
      <DrawerContent className="max-h-[92dvh]">
        <div className="overflow-y-auto px-4 pb-8">
          <DrawerHeader className="px-0">
            <DrawerTitle className="text-left">
              {draft.status === "inbox" ? "Confirm item" : "Edit item"}
            </DrawerTitle>
          </DrawerHeader>

          <div className="space-y-4">
            <div className="space-y-1.5">
              <Label>Title</Label>
              <Input value={draft.title} onChange={(e) => set({ title: e.target.value })} />
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label>Type</Label>
                <Select value={draft.kind} onValueChange={(v) => set({ kind: v as ItemKind })}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="event">Event</SelectItem>
                    <SelectItem value="place">Place</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-1.5">
                <Label>Category</Label>
                <Select
                  value={draft.category ?? undefined}
                  onValueChange={(v) => set({ category: v })}
                >
                  <SelectTrigger><SelectValue placeholder="—" /></SelectTrigger>
                  <SelectContent>
                    {CATEGORIES.map((c) => (
                      <SelectItem key={c} value={c}>{c}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label>Venue</Label>
                <Input value={draft.venue ?? ""} onChange={(e) => set({ venue: e.target.value || null })} />
              </div>
              <div className="space-y-1.5">
                <Label>Area</Label>
                <Input value={draft.area ?? ""} onChange={(e) => set({ area: e.target.value || null })} />
              </div>
            </div>

            {draft.kind === "event" && (
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label>Opens</Label>
                  <Input
                    type="date"
                    value={draft.starts_on ?? ""}
                    onChange={(e) => set({ starts_on: e.target.value || null })}
                  />
                </div>
                <div className="space-y-1.5">
                  <Label>Closes</Label>
                  <Input
                    type="date"
                    value={draft.ends_on ?? ""}
                    onChange={(e) => set({ ends_on: e.target.value || null })}
                  />
                </div>
              </div>
            )}

            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label>Price</Label>
                <Input value={draft.price ?? ""} onChange={(e) => set({ price: e.target.value || null })} />
              </div>
              <div className="space-y-1.5">
                <Label>Planned for</Label>
                <Input
                  type="date"
                  value={draft.planned_for ?? ""}
                  onChange={(e) =>
                    set({
                      planned_for: e.target.value || null,
                      status: e.target.value ? "planned" : draft.status === "planned" ? "saved" : draft.status,
                    })
                  }
                />
              </div>
            </div>

            <div className="space-y-1.5">
              <Label>Notes</Label>
              <Textarea
                value={draft.notes ?? ""}
                onChange={(e) => set({ notes: e.target.value || null })}
                rows={2}
              />
            </div>

            {draft.url && (
              <a
                href={draft.url}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 text-sm underline underline-offset-4"
              >
                Open source link <ArrowUpRight className="size-3.5" />
              </a>
            )}

            <Separator />

            <div className="flex flex-col gap-2">
              {draft.status === "inbox" ? (
                <Button onClick={() => save({ status: draft.planned_for ? "planned" : "saved" })}>
                  <Check /> Confirm &amp; save
                </Button>
              ) : (
                <Button onClick={() => save()}>Save changes</Button>
              )}

              <div className="grid grid-cols-2 gap-2">
                {(draft.planned_for || draft.starts_on) && (
                  <Button variant="outline" onClick={() => downloadIcs(draft)}>
                    <CalendarPlus /> Add to Calendar
                  </Button>
                )}
                {draft.status !== "done" ? (
                  <Button variant="outline" onClick={() => save({ status: "done" })}>
                    <Check /> Mark done
                  </Button>
                ) : (
                  <Button variant="outline" onClick={() => save({ status: "saved" })}>
                    <Undo2 /> Not done yet
                  </Button>
                )}
              </div>

              <Button
                variant="ghost"
                className="text-muted-foreground"
                onClick={async () => {
                  await softDeleteItem(draft.id);
                  toast("Deleted");
                  onChanged();
                  onClose();
                }}
              >
                <Trash2 /> Delete
              </Button>
            </div>
          </div>
        </div>
      </DrawerContent>
    </Drawer>
  );
}
