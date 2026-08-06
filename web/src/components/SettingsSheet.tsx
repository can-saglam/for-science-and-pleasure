import { useState } from "react";
import {
  Check,
  FileDown,
  Loader2,
  LogOut,
  MapPin,
  Monitor,
  Moon,
  Newspaper,
  NotebookPen,
  RefreshCw,
  Settings as SettingsIcon,
  Sun,
} from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { isActive, proposeLocations, updateItem } from "@/lib/api";
import { getThemePref, setThemePref, type ThemePref } from "@/lib/theme";
import {
  exportSavesAsMarkdown,
  exportSavesForAppleNotes,
} from "@/lib/export-saves";
import type { Item, LocationProposal } from "@/lib/types";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from "@/components/ui/drawer";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { NotificationSettings } from "@/components/NotificationSettings";

export function SettingsSheet({
  email,
  items,
  onOpenDigest,
}: {
  email?: string;
  items: Item[];
  onOpenDigest: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [theme, setTheme] = useState<ThemePref>(getThemePref);
  const [refreshing, setRefreshing] = useState(false);
  const [locating, setLocating] = useState(false);
  const [proposals, setProposals] = useState<LocationProposal[] | null>(null);
  const [accepted, setAccepted] = useState<Set<string>>(new Set());
  const [applying, setApplying] = useState(false);

  const missing = items.filter(
    (i) => isActive(i) && (i.lat == null || i.lng == null),
  );

  async function findLocations() {
    setLocating(true);
    try {
      const result = await proposeLocations(missing.slice(0, 20));
      setProposals(result);
      setAccepted(new Set(result.filter((p) => p.lat != null).map((p) => p.id)));
    } catch (e) {
      toast.error(`Couldn't find locations: ${e instanceof Error ? e.message : e}`);
    } finally {
      setLocating(false);
    }
  }

  function toggleAccepted(id: string) {
    setAccepted((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  async function applyLocations() {
    if (!proposals) return;
    setApplying(true);
    try {
      const chosen = proposals.filter((p) => accepted.has(p.id) && p.lat != null);
      for (const p of chosen) {
        const item = items.find((i) => i.id === p.id);
        const patch: Partial<Item> = { lat: p.lat, lng: p.lng };
        // Only fill blanks — never overwrite details you typed yourself.
        if (!item?.venue && p.venue) patch.venue = p.venue;
        if (!item?.area && p.area) patch.area = p.area;
        if (!item?.address && p.address) patch.address = p.address;
        await updateItem(p.id, patch);
      }
      toast.success(
        `Added ${chosen.length} location${chosen.length === 1 ? "" : "s"}`,
      );
      setProposals(null);
    } catch (e) {
      toast.error(`Couldn't save: ${e instanceof Error ? e.message : e}`);
    } finally {
      setApplying(false);
    }
  }

  async function forceRefresh() {
    setRefreshing(true);
    if ("caches" in window) {
      const keys = await caches.keys();
      await Promise.all(keys.map((key) => caches.delete(key)));
    }
    if ("serviceWorker" in navigator) {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(registrations.map((registration) => registration.update()));
    }
    const url = new URL(window.location.href);
    url.searchParams.set("_refresh", Date.now().toString());
    window.location.replace(url);
  }

  return (
    <>
      <Button
        variant="ghost"
        size="icon"
        className="text-muted-foreground"
        aria-label="Settings"
        title="Settings"
        onClick={() => setOpen(true)}
      >
        <SettingsIcon />
      </Button>

      <Drawer open={open} onOpenChange={setOpen}>
        <DrawerContent className="max-h-[92dvh]">
          <div className="mx-auto w-full max-w-lg overflow-y-auto px-4 pb-8">
            <DrawerHeader className="px-0 text-left">
              <DrawerTitle>Settings</DrawerTitle>
              <DrawerDescription>
                Notifications, app controls, and your account.
              </DrawerDescription>
            </DrawerHeader>

            <div className="space-y-4">
              <section className="space-y-3 rounded-xl border p-4">
                <div>
                  <h3 className="font-medium">Appearance</h3>
                  <p className="mt-1 text-sm text-muted-foreground">
                    System follows your device's light/dark setting.
                  </p>
                </div>
                <div className="grid grid-cols-3 gap-1 rounded-lg border p-1">
                  {(
                    [
                      { id: "light", label: "Light", icon: Sun },
                      { id: "system", label: "System", icon: Monitor },
                      { id: "dark", label: "Dark", icon: Moon },
                    ] as const
                  ).map(({ id, label, icon: Icon }) => (
                    <button
                      key={id}
                      onClick={() => {
                        setTheme(id);
                        setThemePref(id);
                      }}
                      className={cn(
                        "flex min-h-9 items-center justify-center gap-1.5 rounded-md text-sm",
                        theme === id
                          ? "bg-foreground font-medium text-background"
                          : "text-muted-foreground",
                      )}
                    >
                      <Icon className="size-4" /> {label}
                    </button>
                  ))}
                </div>
              </section>

              <NotificationSettings />

              <section className="space-y-3 rounded-xl border p-4">
                <div>
                  <h3 className="font-medium">App</h3>
                  <p className="mt-1 text-sm text-muted-foreground">
                    Clear cached files and load the latest version.
                  </p>
                </div>
                <Button
                  variant="outline"
                  className="w-full"
                  disabled={refreshing}
                  onClick={forceRefresh}
                >
                  {refreshing ? (
                    <Loader2 className="animate-spin" />
                  ) : (
                    <RefreshCw />
                  )}
                  Force refresh
                </Button>
              </section>

              <section className="space-y-3 rounded-xl border p-4">
                <div>
                  <h3 className="font-medium">Weekly digest</h3>
                  <p className="mt-1 text-sm text-muted-foreground">
                    See this week's summary — the same one the Tuesday
                    notification points to. Nothing is sent.
                  </p>
                </div>
                <Button
                  variant="outline"
                  className="w-full"
                  onClick={() => {
                    setOpen(false);
                    onOpenDigest();
                  }}
                >
                  <Newspaper />
                  Preview weekly digest
                </Button>
              </section>

              <section className="space-y-3 rounded-xl border p-4">
                <div>
                  <h3 className="font-medium">Export saves</h3>
                  <p className="mt-1 text-sm text-muted-foreground">
                    Download the whole library, including completed items. On a
                    Mac, import the ENEX file from Notes → File → Import to
                    Notes.
                  </p>
                </div>
                <div className="grid gap-2 sm:grid-cols-2">
                  <Button
                    variant="outline"
                    onClick={() => exportSavesForAppleNotes(items)}
                  >
                    <NotebookPen />
                    Apple Notes
                  </Button>
                  <Button
                    variant="outline"
                    onClick={() => exportSavesAsMarkdown(items)}
                  >
                    <FileDown />
                    Markdown
                  </Button>
                </div>
              </section>

              <section className="space-y-3 rounded-xl border p-4">
                <div>
                  <h3 className="font-medium">Missing locations</h3>
                  <p className="mt-1 text-sm text-muted-foreground">
                    {missing.length === 0
                      ? "Every active save has a spot on the map."
                      : `${missing.length} active save${missing.length === 1 ? "" : "s"} can't show on the map. Let AI work out where they are — you confirm before anything is saved.`}
                  </p>
                </div>
                <Button
                  variant="outline"
                  className="w-full"
                  disabled={locating || missing.length === 0}
                  onClick={findLocations}
                >
                  {locating ? <Loader2 className="animate-spin" /> : <MapPin />}
                  {locating ? "Working it out…" : "Find locations with AI"}
                </Button>
              </section>

              <section className="space-y-3 rounded-xl border p-4">
                <div>
                  <h3 className="font-medium">Account</h3>
                  {email && (
                    <p className="mt-1 truncate text-sm text-muted-foreground">
                      Signed in as {email}
                    </p>
                  )}
                </div>
                <Button
                  variant="outline"
                  className="w-full text-destructive"
                  onClick={() => supabase.auth.signOut()}
                >
                  <LogOut />
                  Sign out
                </Button>
              </section>
            </div>
          </div>
        </DrawerContent>
      </Drawer>

      <Dialog
        open={proposals !== null}
        onOpenChange={(o) => {
          if (!o && !applying) setProposals(null);
        }}
      >
        {/* Pinned to the viewport edges on mobile (no translate/percentage
            centring, which iOS Safari miscalculates and overflows the screen) */}
        <DialogContent className="left-4 right-4 z-[60] max-h-[80dvh] w-auto max-w-none translate-x-0 overflow-y-auto sm:left-1/2 sm:right-auto sm:w-full sm:max-w-md sm:-translate-x-1/2">
          <DialogHeader>
            <DialogTitle>Confirm locations</DialogTitle>
            <DialogDescription>
              Tap to include or skip. Only ticked items are saved; existing
              details are never overwritten.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-2">
            {(proposals ?? []).map((p) => {
              const item = items.find((i) => i.id === p.id);
              const found = p.lat != null;
              const on = accepted.has(p.id);
              const where = [p.venue, p.area].filter(Boolean).join(" · ");
              return (
                <button
                  key={p.id}
                  disabled={!found}
                  onClick={() => toggleAccepted(p.id)}
                  className={cn(
                    "flex w-full items-start gap-3 rounded-lg border p-3 text-left",
                    on ? "border-foreground" : "border-border",
                    !found && "opacity-50",
                  )}
                >
                  <span
                    className={cn(
                      "mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border",
                      on
                        ? "border-foreground bg-foreground text-background"
                        : "border-muted-foreground/40",
                    )}
                  >
                    {on && <Check className="size-3.5" strokeWidth={3} />}
                  </span>
                  <span className="min-w-0">
                    <span className="block truncate font-medium">
                      {item?.title ?? "Unknown item"}
                    </span>
                    {found ? (
                      <>
                        {where && (
                          <span className="block text-sm text-muted-foreground">
                            {where}
                          </span>
                        )}
                        {p.address && (
                          <span className="block text-xs text-muted-foreground">
                            {p.address}
                          </span>
                        )}
                        {p.confidence === "low" && (
                          <span className="block text-xs text-muted-foreground">
                            Best guess — worth double-checking
                          </span>
                        )}
                      </>
                    ) : (
                      <span className="block text-sm text-muted-foreground">
                        Couldn't pin this one down
                      </span>
                    )}
                  </span>
                </button>
              );
            })}
          </div>

          <DialogFooter>
            <Button
              variant="outline"
              disabled={applying}
              onClick={() => setProposals(null)}
            >
              Cancel
            </Button>
            <Button
              disabled={applying || accepted.size === 0}
              onClick={applyLocations}
            >
              {applying && <Loader2 className="animate-spin" />}
              Add {accepted.size} location{accepted.size === 1 ? "" : "s"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
