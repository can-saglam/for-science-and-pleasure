import { useEffect, useState } from "react";
import { format, parseISO } from "date-fns";
import { Loader2 } from "lucide-react";
import { fetchDigest } from "@/lib/api";
import type { Digest } from "@/lib/types";
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from "@/components/ui/drawer";

export function DigestSheet({
  digestId,
  onClose,
}: {
  digestId: string | null;
  onClose: () => void;
}) {
  const [digest, setDigest] = useState<Digest | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!digestId) {
      setDigest(null);
      setError(null);
      return;
    }

    let cancelled = false;
    fetchDigest(digestId)
      .then((value) => {
        if (!cancelled) setDigest(value);
      })
      .catch(() => {
        if (!cancelled) setError("This digest could not be loaded.");
      });
    return () => {
      cancelled = true;
    };
  }, [digestId]);

  return (
    <Drawer open={Boolean(digestId)} onOpenChange={(open) => !open && onClose()}>
      <DrawerContent>
        <div className="mx-auto w-full max-w-lg px-4 pb-8">
          <DrawerHeader className="px-0 text-left">
            <DrawerTitle>This week</DrawerTitle>
            <DrawerDescription>
              {digest
                ? `Week of ${format(parseISO(digest.week_start), "d MMMM")}`
                : "Your Tuesday heads-up"}
            </DrawerDescription>
          </DrawerHeader>

          {!digest && !error && (
            <div className="flex min-h-28 items-center justify-center">
              <Loader2 className="size-5 animate-spin text-muted-foreground" />
            </div>
          )}
          {error && <p className="py-4 text-sm text-destructive">{error}</p>}
          {digest && (
            <p className="whitespace-pre-wrap text-base leading-relaxed">{digest.text}</p>
          )}
        </div>
      </DrawerContent>
    </Drawer>
  );
}
