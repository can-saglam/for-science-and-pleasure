import { useRef, useState } from "react";
import { findByUrl, insertItem, parseInput } from "@/lib/api";
import type { Item } from "@/lib/types";
import { imageTooLargeMessage, MAX_IMAGE_BYTES } from "@/lib/limits";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import { ImageIcon, PenLine, Sparkles } from "lucide-react";

async function fileToBase64(file: File): Promise<string> {
  const buf = await file.arrayBuffer();
  let binary = "";
  const bytes = new Uint8Array(buf);
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function Capture({ onCreated }: { onCreated: (item: Item) => void }) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);

  async function handleParse() {
    if (!text.trim() && !file) return;
    setBusy(true);
    try {
      const payload: Parameters<typeof parseInput>[0] = {};
      if (text.trim()) payload.text = text.trim();
      if (file) {
        if (file.size > MAX_IMAGE_BYTES) {
          throw new Error(imageTooLargeMessage());
        }
        payload.image_base64 = await fileToBase64(file);
        payload.image_media_type = file.type || "image/jpeg";
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

      const item = await insertItem({
        kind: card.kind,
        status: "saved",
        title: card.title,
        summary: card.summary,
        venue: card.venue,
        area: card.area,
        address: card.address,
        category: card.category,
        price: card.price,
        url: card.url,
        booking_url: card.booking_url,
        starts_on: card.starts_on,
        ends_on: card.ends_on,
        lat: card.lat,
        lng: card.lng,
        color: card.color,
        source: card.source,
        raw_input: text.trim() || "(screenshot)",
      });
      setText("");
      setFile(null);
      onCreated(item);
    } catch (e) {
      toast.error(`Couldn't parse: ${e instanceof Error ? e.message : e}`);
    } finally {
      setBusy(false);
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
            onChange={(e) => {
              const next = e.target.files?.[0] ?? null;
              if (next && next.size > MAX_IMAGE_BYTES) {
                toast.error(imageTooLargeMessage());
                e.target.value = "";
                setFile(null);
                return;
              }
              setFile(next);
            }}
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
        <Sparkles /> {busy ? "Parsing…" : "Parse & save"}
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
