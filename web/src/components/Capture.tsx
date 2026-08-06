import { useRef, useState } from "react";
import { findByUrl, insertItem, notifyPartnerOfSave, parseInput } from "@/lib/api";
import type { Item, ItemKind, ParsedCard } from "@/lib/types";
import { CATEGORIES } from "@/lib/types";
import { imageTooLargeMessage, MAX_IMAGE_BYTES } from "@/lib/limits";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { ItemCard } from "@/components/ItemCard";
import { toast } from "sonner";
import {
  Check,
  ImageIcon,
  PenLine,
  Pencil,
  Sparkles,
  Trash2,
  X,
} from "lucide-react";

async function bytesToBase64(buf: ArrayBuffer): Promise<string> {
  let binary = "";
  const bytes = new Uint8Array(buf);
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

// Phone screenshots are multi-MB PNGs (often HEIC from the photo library);
// downscale + re-encode as JPEG so any attachment fits the parse limits
// with text still crisp enough for the model to read.
async function compressImage(
  file: File,
): Promise<{ base64: string; mediaType: string }> {
  try {
    const bitmap = await createImageBitmap(file);
    const MAX_EDGE = 2000;
    const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close();
    const blob = await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob(
        (b) => (b ? resolve(b) : reject(new Error("encode failed"))),
        "image/jpeg",
        0.85,
      ),
    );
    return {
      base64: await bytesToBase64(await blob.arrayBuffer()),
      mediaType: "image/jpeg",
    };
  } catch {
    // Undecodable format — send the original and let the size check decide.
    if (file.size > MAX_IMAGE_BYTES) throw new Error(imageTooLargeMessage());
    return {
      base64: await bytesToBase64(await file.arrayBuffer()),
      mediaType: file.type || "image/jpeg",
    };
  }
}

type Draft = ParsedCard & { notes: string | null };

// Native date inputs on iOS are hard to empty once set, so give the
// draft form the same clearable date field the item sheet uses.
function ClearableDate({
  value,
  onChange,
}: {
  value: string | null;
  onChange: (v: string | null) => void;
}) {
  return (
    <div className="relative min-w-0">
      <Input
        type="date"
        value={value ?? ""}
        onChange={(e) => onChange(e.target.value || null)}
        style={{ width: "100%", minWidth: 0, maxWidth: "100%" }}
        className={
          value
            ? "pr-9 [&::-webkit-calendar-picker-indicator]:opacity-0"
            : undefined
        }
      />
      {value && (
        <button
          type="button"
          aria-label="Clear date"
          onClick={() => onChange(null)}
          className="absolute inset-y-0 right-0 flex w-8 touch-manipulation items-center justify-center rounded-r-lg text-muted-foreground hover:text-foreground"
        >
          <X className="size-4" />
        </button>
      )}
    </div>
  );
}

export function Capture({
  onCreated,
  onSaved,
}: {
  /** Blank manual items / already-saved duplicates: open the item sheet. */
  onCreated: (item: Item) => void;
  /** A confirmed save from the preview: just close and refresh. */
  onSaved: (item: Item) => void;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);

  async function handleParse() {
    if (!text.trim() && !file) return;
    setBusy(true);
    try {
      const payload: Parameters<typeof parseInput>[0] = {};
      if (text.trim()) payload.text = text.trim();
      if (file) {
        const compressed = await compressImage(file);
        payload.image_base64 = compressed.base64;
        payload.image_media_type = compressed.mediaType;
      }
      const card = await parseInput(payload);

      if (card.url) {
        const existing = await findByUrl(card.url);
        if (existing) {
          toast(`Already saved: ${existing.title}`);
          setText("");
          setFile(null);
          onCreated(existing);
          return;
        }
      }

      setDraft({ ...card, notes: null });
      setEditing(false);
    } catch (e) {
      toast.error(`Couldn't parse: ${e instanceof Error ? e.message : e}`);
    } finally {
      setBusy(false);
    }
  }

  async function handleSave() {
    if (!draft) return;
    setSaving(true);
    try {
      const item = await insertItem({
        kind: draft.kind,
        status: "saved",
        title: draft.title,
        summary: draft.summary,
        venue: draft.venue,
        area: draft.area,
        address: draft.address,
        category: draft.category,
        price: draft.price,
        url: draft.url,
        booking_url: draft.booking_url,
        starts_on: draft.starts_on,
        ends_on: draft.ends_on,
        lat: draft.lat,
        lng: draft.lng,
        color: draft.color,
        image_url: draft.image_url,
        notes: draft.notes,
        source: draft.source,
        raw_input: text.trim() || "(screenshot)",
      });
      setText("");
      setFile(null);
      setDraft(null);
      notifyPartnerOfSave(item.id);
      toast.success(`Saved: ${item.title}`);
      onSaved(item);
    } catch (e) {
      toast.error(`Couldn't save: ${e instanceof Error ? e.message : e}`);
    } finally {
      setSaving(false);
    }
  }

  async function handleManual() {
    const item = await insertItem({
      kind: "place",
      status: "saved",
      title: "New item",
      source: "manual",
    });
    onCreated(item);
  }

  const set = (patch: Partial<Draft>) =>
    setDraft((d) => (d ? { ...d, ...patch } : d));

  /* ---------------- preview & edit (after parse, before save) -------- */
  if (draft) {
    // A throwaway Item so the preview renders exactly like a library card.
    const previewItem: Item = {
      id: "draft-preview",
      status: "saved",
      image_url: null,
      planned_for: null,
      raw_input: null,
      added_by_email: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      deleted_at: null,
      ...draft,
    };

    return (
      <div className="space-y-4">
        {!editing ? (
          <>
            <p className="text-sm text-muted-foreground">
              Here's what will be saved — check it over first.
            </p>
            <div className="pointer-events-none">
              <ItemCard item={previewItem} />
            </div>
            {draft.summary && (
              <p className="text-sm text-muted-foreground">{draft.summary}</p>
            )}

            <Button className="w-full" disabled={saving} onClick={handleSave}>
              <Check /> {saving ? "Saving…" : "Save to library"}
            </Button>
            <Button
              variant="outline"
              className="w-full"
              disabled={saving}
              onClick={() => setEditing(true)}
            >
              <Pencil /> Edit first
            </Button>
          </>
        ) : (
          <>
            <div className="space-y-1.5">
              <Label>Title</Label>
              <Input
                value={draft.title}
                onChange={(e) => set({ title: e.target.value })}
              />
            </div>

            <div className="grid min-w-0 grid-cols-2 gap-3 [&>*]:min-w-0">
              <div className="space-y-1.5">
                <Label>Type</Label>
                <Select
                  value={draft.kind}
                  onValueChange={(v) => set({ kind: v as ItemKind })}
                >
                  <SelectTrigger className="w-full min-w-0">
                    <SelectValue />
                  </SelectTrigger>
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
                  <SelectTrigger className="w-full min-w-0">
                    <SelectValue placeholder="—" />
                  </SelectTrigger>
                  <SelectContent>
                    {CATEGORIES.map((c) => (
                      <SelectItem key={c} value={c}>
                        {c}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>

            <div className="grid min-w-0 grid-cols-2 gap-3 [&>*]:min-w-0">
              <div className="space-y-1.5">
                <Label>Venue</Label>
                <Input
                  value={draft.venue ?? ""}
                  onChange={(e) => set({ venue: e.target.value || null })}
                />
              </div>
              <div className="space-y-1.5">
                <Label>Area</Label>
                <Input
                  value={draft.area ?? ""}
                  onChange={(e) => set({ area: e.target.value || null })}
                />
              </div>
            </div>

            {draft.kind === "event" && (
              <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2 [&>*]:min-w-0">
                <div className="space-y-1.5">
                  <Label>Opens</Label>
                  <ClearableDate
                    value={draft.starts_on}
                    onChange={(v) => set({ starts_on: v })}
                  />
                </div>
                <div className="space-y-1.5">
                  <Label>Closes</Label>
                  <ClearableDate
                    value={draft.ends_on}
                    onChange={(v) => set({ ends_on: v })}
                  />
                </div>
              </div>
            )}

            <div className="space-y-1.5">
              <Label>Price</Label>
              <Input
                value={draft.price ?? ""}
                onChange={(e) => set({ price: e.target.value || null })}
              />
            </div>

            <div className="space-y-1.5">
              <Label>Notes</Label>
              <Textarea
                value={draft.notes ?? ""}
                onChange={(e) => set({ notes: e.target.value || null })}
                rows={3}
              />
            </div>

            <Button className="w-full" disabled={saving} onClick={handleSave}>
              <Check /> {saving ? "Saving…" : "Save to library"}
            </Button>
            <Button
              variant="outline"
              className="w-full"
              disabled={saving}
              onClick={() => setEditing(false)}
            >
              Back to preview
            </Button>
          </>
        )}

        <Button
          variant="ghost"
          className="w-full text-muted-foreground"
          disabled={saving}
          onClick={() => {
            setDraft(null);
            setEditing(false);
          }}
        >
          <Trash2 /> Discard
        </Button>
      </div>
    );
  }

  /* ---------------- input form ---------------- */
  return (
    <div className="space-y-4">
      <div className="space-y-2">
        <Textarea
          placeholder={"Paste a link, or any text about an event or place…\n\ne.g. https://barbican.org.uk/whats-on/…"}
          rows={5}
          value={text}
          onChange={(e) => setText(e.target.value)}
          className="resize-none text-base"
        />
        <div className="flex items-center gap-2">
          <input
            ref={fileRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(e) => setFile(e.target.files?.[0] ?? null)}
          />
          <Button
            variant="outline"
            size="sm"
            onClick={() => fileRef.current?.click()}
          >
            <ImageIcon /> {file ? file.name.slice(0, 18) : "Add screenshot"}
          </Button>
          {file && (
            <Button variant="ghost" size="sm" onClick={() => setFile(null)}>
              remove
            </Button>
          )}
        </div>
      </div>

      <Button
        className="w-full"
        disabled={busy || (!text.trim() && !file)}
        onClick={handleParse}
      >
        <Sparkles /> {busy ? "Reading…" : "Parse"}
      </Button>

      <Button variant="outline" className="w-full" onClick={handleManual}>
        <PenLine /> Add manually
      </Button>

      <p className="text-center text-xs leading-relaxed text-muted-foreground">
        Instagram links can't be read directly — attach a screenshot of the
        post and we'll read that instead. From Safari or Instagram, use the
        share-sheet Shortcut to dump things here in one tap.
      </p>
    </div>
  );
}
