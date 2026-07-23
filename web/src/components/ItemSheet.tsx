import { useEffect, useMemo, useState } from "react";
import { format, parseISO } from "date-fns";
import {
  downloadIcs,
  googleDirectionsUrl,
  googleMapsUrl,
  haversineKm,
  isActive,
  softDeleteItem,
  updateItem,
  walkMinutes,
} from "@/lib/api";
import type { Item, ItemKind, Member } from "@/lib/types";
import { CATEGORIES } from "@/lib/types";
import { Badge } from "@/components/ui/badge";
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
import { TimeBadge, windowLabel } from "./ItemCard";
import {
  ArrowUpRight,
  CalendarPlus,
  Check,
  MapPin,
  Pencil,
  Trash2,
  Undo2,
} from "lucide-react";

function normalizeArea(area: string | null): string | null {
  return area ? area.trim().toLowerCase() : null;
}

export function ItemSheet({
  item,
  allItems,
  members,
  onClose,
  onChanged,
  onSwitch,
}: {
  item: Item | null;
  allItems: Item[];
  members: Member[];
  onClose: () => void;
  onChanged: () => void;
  onSwitch: (item: Item) => void;
}) {
  const [draft, setDraft] = useState<Item | null>(item);
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    setDraft(item);
    setEditing(item?.status === "inbox");
  }, [item]);

  const nearby = useMemo(() => {
    if (!item || item.kind !== "event") return [];
    const places = allItems.filter(
      (p) => p.id !== item.id && p.kind === "place" && isActive(p),
    );
    // Preferred: real distance when both sides are geocoded (≤ 2 km).
    if (item.lat && item.lng) {
      const withDist = places
        .filter((p) => p.lat && p.lng)
        .map((p) => ({
          place: p,
          km: haversineKm(
            { lat: item.lat!, lng: item.lng! },
            { lat: p.lat!, lng: p.lng! },
          ),
        }))
        .filter(({ km }) => km <= 2)
        .sort((a, b) => a.km - b.km)
        .slice(0, 3);
      if (withDist.length > 0) return withDist;
    }
    // Fallback: same-area name match for items without coordinates.
    const area = normalizeArea(item.area);
    if (!area) return [];
    return places
      .filter((p) => normalizeArea(p.area) === area)
      .slice(0, 3)
      .map((place) => ({ place, km: null as number | null }));
  }, [item, allItems]);

  const addedBy = useMemo(() => {
    if (!item?.added_by_email) return null;
    const m = members.find((m) => m.email === item.added_by_email);
    return m?.display_name ?? item.added_by_email.split("@")[0];
  }, [item, members]);

  if (!draft) return <Drawer open={false} />;

  const set = (patch: Partial<Item>) => setDraft({ ...draft, ...patch });

  async function persist(patch: Partial<Item>, closeAfter = true) {
    if (!draft) return;
    try {
      await updateItem(draft.id, patch);
      onChanged();
      if (closeAfter) onClose();
    } catch (e) {
      toast.error(String(e));
    }
  }

  function save(extra: Partial<Item> = {}) {
    if (!draft) return;
    persist({
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
  }

  const label = windowLabel(draft);

  return (
    <Drawer open={!!item} onOpenChange={(open) => !open && onClose()}>
      <DrawerContent className="max-h-[92dvh]">
        <div className="overflow-y-auto px-4 pb-8">
          {!editing ? (
            /* ---------------- read-only view ---------------- */
            <>
              <DrawerHeader className="px-0 pb-2">
                <DrawerTitle className="pr-8 text-left text-xl leading-snug">
                  {draft.title}
                </DrawerTitle>
              </DrawerHeader>

              <div className="flex flex-wrap items-center gap-1.5">
                <TimeBadge item={draft} />
                {draft.category && <Badge variant="outline">{draft.category}</Badge>}
                {draft.price && <Badge variant="outline">{draft.price}</Badge>}
                {draft.status === "done" && <Badge variant="secondary">done</Badge>}
              </div>

              <div className="mt-3 space-y-1 text-sm">
                {(draft.venue || draft.area) && (
                  <p>{[draft.venue, draft.area].filter(Boolean).join(" · ")}</p>
                )}
                {label && <p className="text-muted-foreground">{label}</p>}
                {draft.planned_for && (
                  <p className="font-medium">
                    Planned for {format(parseISO(draft.planned_for), "EEEE d MMMM")}
                  </p>
                )}
                {draft.summary && (
                  <p className="pt-1 text-muted-foreground">{draft.summary}</p>
                )}
                {draft.notes && (
                  <p className="pt-1 whitespace-pre-wrap">{draft.notes}</p>
                )}
                {addedBy && (
                  <p className="pt-1 text-xs text-muted-foreground">
                    Added by {addedBy}
                  </p>
                )}
              </div>

              <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1">
                <a
                  href={googleMapsUrl(draft)}
                  target="_blank"
                  rel="noreferrer"
                  className="inline-flex items-center gap-1 text-sm underline underline-offset-4"
                >
                  <MapPin className="size-3.5" /> Google Maps
                </a>
                {draft.url && (
                  <a
                    href={draft.url}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1 text-sm underline underline-offset-4"
                  >
                    Source link <ArrowUpRight className="size-3.5" />
                  </a>
                )}
              </div>

              <div className="mt-4 space-y-1.5">
                <Label className="text-muted-foreground">Plan for a day</Label>
                <Input
                  type="date"
                  value={draft.planned_for ?? ""}
                  onChange={(e) => {
                    const v = e.target.value || null;
                    set({ planned_for: v, status: v ? "planned" : "saved" });
                    persist(
                      { planned_for: v, status: v ? "planned" : "saved" },
                      false,
                    );
                  }}
                />
              </div>

              <div className="mt-4 grid grid-cols-2 gap-2">
                <Button variant="outline" onClick={() => setEditing(true)}>
                  <Pencil /> Edit
                </Button>
                {draft.status !== "done" ? (
                  <Button variant="outline" onClick={() => save({ status: "done" })}>
                    <Check /> Mark done
                  </Button>
                ) : (
                  <Button variant="outline" onClick={() => save({ status: "saved" })}>
                    <Undo2 /> Not done yet
                  </Button>
                )}
                {(draft.planned_for || draft.starts_on) && (
                  <Button
                    variant="outline"
                    className="col-span-2"
                    onClick={() => downloadIcs(draft)}
                  >
                    <CalendarPlus /> Add to Calendar
                  </Button>
                )}
              </div>

              {nearby.length > 0 && (
                <div className="mt-6 space-y-2">
                  <Separator />
                  <div className="flex items-center gap-1.5 pt-2">
                    <MapPin className="size-4" />
                    <h3 className="font-heading text-sm font-semibold">
                      Make a day of it
                    </h3>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    Saved spots near this you could pair with it.
                  </p>
                  {nearby.map(({ place: p, km }) => (
                    <div
                      key={p.id}
                      className="flex items-center gap-2 rounded-xl border bg-card px-4 py-3"
                    >
                      <button onClick={() => onSwitch(p)} className="min-w-0 flex-1 text-left">
                        <div className="truncate font-medium leading-snug">{p.title}</div>
                        <div className="truncate text-sm text-muted-foreground">
                          {[
                            p.category,
                            p.area,
                            km !== null ? `~${walkMinutes(km)} min walk` : null,
                          ]
                            .filter(Boolean)
                            .join(" · ")}
                        </div>
                      </button>
                      <a
                        href={googleDirectionsUrl(draft, p)}
                        target="_blank"
                        rel="noreferrer"
                        aria-label={`Walking directions to ${p.title}`}
                        className="shrink-0 rounded-md border p-2 text-muted-foreground active:bg-accent"
                      >
                        <ArrowUpRight className="size-4" />
                      </a>
                    </div>
                  ))}
                </div>
              )}
            </>
          ) : (
            /* ---------------- edit form ---------------- */
            <>
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
                          status: e.target.value
                            ? "planned"
                            : draft.status === "planned"
                              ? "saved"
                              : draft.status,
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

                <Separator />

                <div className="flex flex-col gap-2">
                  {draft.status === "inbox" ? (
                    <Button onClick={() => save({ status: draft.planned_for ? "planned" : "saved" })}>
                      <Check /> Confirm &amp; save
                    </Button>
                  ) : (
                    <div className="grid grid-cols-2 gap-2">
                      <Button variant="outline" onClick={() => setEditing(false)}>
                        Cancel
                      </Button>
                      <Button onClick={() => save()}>Save changes</Button>
                    </div>
                  )}

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
            </>
          )}
        </div>
      </DrawerContent>
    </Drawer>
  );
}
