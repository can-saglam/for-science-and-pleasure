import { useCallback, useEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { fetchItems, fetchMembers } from "@/lib/api";
import type { Item, Member } from "@/lib/types";
import { PlanDay } from "@/components/PlanDay";
import { Auth } from "@/components/Auth";
import { Capture } from "@/components/Capture";
import { Library } from "@/components/Library";
import { CalendarMonth } from "@/components/CalendarMonth";
import { ThisWeek } from "@/components/ThisWeek";
import { WeDidGo } from "@/components/WeDidGo";
import { ItemSheet } from "@/components/ItemSheet";
import { DigestSheet } from "@/components/DigestSheet";
import { SettingsSheet } from "@/components/SettingsSheet";
import { Toaster } from "@/components/ui/sonner";
import {
  Drawer,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
} from "@/components/ui/drawer";
import { cn } from "@/lib/utils";
import { DEMO_ITEMS } from "@/lib/demo";
import {
  CalendarDays,
  Footprints,
  LibraryBig,
  Loader2,
  Palette,
  Plus,
} from "lucide-react";
import { toast } from "sonner";

const DEMO = new URLSearchParams(window.location.search).has("demo");
const INITIAL_DIGEST = new URLSearchParams(window.location.search).get("digest");

type Tab = "week" | "calendar" | "library" | "did";

const TABS: { id: Tab; label: string; icon: React.ElementType }[] = [
  { id: "week", label: "This Week", icon: Palette },
  { id: "calendar", label: "Calendar", icon: CalendarDays },
  { id: "library", label: "Library", icon: LibraryBig },
  { id: "did", label: "We Did Go", icon: Footprints },
];

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [items, setItems] = useState<Item[]>([]);
  const [tab, setTab] = useState<Tab>("week");
  const [selected, setSelected] = useState<Item | null>(null);
  const [captureOpen, setCaptureOpen] = useState(false);
  const [members, setMembers] = useState<Member[]>([]);
  const [digestId, setDigestId] = useState<string | null>(INITIAL_DIGEST);
  const hasLoadedItems = useRef(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setAuthReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const refresh = useCallback(async () => {
    if (DEMO) {
      setItems(DEMO_ITEMS);
      hasLoadedItems.current = true;
      return;
    }
    try {
      setItems(await fetchItems());
      hasLoadedItems.current = true;
    } catch {
      // Avoid toast spam on focus/realtime retries once we have data.
      if (!hasLoadedItems.current) {
        toast.error("Couldn't load your list. Try again in a moment.");
      }
    }
  }, []);

  useEffect(() => {
    if (DEMO) setItems(DEMO_ITEMS);
  }, []);

  useEffect(() => {
    if (INITIAL_DIGEST) {
      const url = new URL(window.location.href);
      url.searchParams.delete("digest");
      window.history.replaceState(null, "", url);
    }

    const onMessage = (event: MessageEvent) => {
      if (event.data?.type === "OPEN_DIGEST" && event.data.digestId) {
        setDigestId(event.data.digestId);
      }
    };
    navigator.serviceWorker?.addEventListener("message", onMessage);
    return () => navigator.serviceWorker?.removeEventListener("message", onMessage);
  }, []);

  useEffect(() => {
    if (!session) return;
    refresh();
    fetchMembers().then(setMembers);
    const onFocus = () => refresh();
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onFocus);
    return () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onFocus);
    };
  }, [session, refresh]);

  // Live sync: any change to items by either member refreshes both devices.
  useEffect(() => {
    if (!session || DEMO) return;
    const channel = supabase
      .channel("items-live")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "items" },
        () => refresh(),
      )
      .subscribe();
    return () => {
      supabase.removeChannel(channel);
    };
  }, [session, refresh]);

  if (!DEMO) {
    if (!authReady) {
      return (
        <div className="flex min-h-dvh items-center justify-center">
          <Loader2
            className="size-6 animate-spin text-muted-foreground"
            aria-label="Loading"
          />
        </div>
      );
    }
    if (!session) return <Auth />;
  }

  return (
    // No overflow rules anywhere above the sticky bars: WebKit stops compositing
    // position:sticky under clipped ancestors and updates it on the main thread,
    // which stutters. (svh, not dvh — dvh re-resolves as the Safari toolbar
    // collapses mid-scroll, relayouting every frame.)
    <div className="mx-auto flex min-h-svh w-full min-w-0 max-w-xl flex-col md:max-w-3xl lg:max-w-5xl">
      {/* translateZ(0) keeps the sticky bars on their own compositor layer so they don't jitter during scroll */}
      <header className="sticky top-0 z-30 flex w-full min-w-0 transform-gpu items-center justify-between gap-4 bg-background px-4 pb-2 pt-[calc(1.25rem+env(safe-area-inset-top))] will-change-transform md:pt-8">
        {/* leading-8 pins the header to a known height (60px / 72px) that the tabs' sticky offsets rely on */}
        <h1 className="min-w-0 truncate font-heading text-xl font-semibold leading-8 tracking-tight md:text-2xl">
          Can We Go?
        </h1>
        {/* desktop nav — the bottom bar is mobile-only */}
        <nav className="hidden items-center gap-1 md:flex" aria-label="Primary">
          {TABS.map(({ id, label }) => (
            <button
              key={id}
              type="button"
              onClick={() => setTab(id)}
              aria-current={tab === id ? "page" : undefined}
              className={cn(
                "relative rounded-full px-4 py-1.5 text-sm transition-colors",
                tab === id
                  ? "bg-foreground text-background"
                  : "text-muted-foreground hover:bg-accent hover:text-foreground",
              )}
            >
              {label}
            </button>
          ))}
        </nav>
        {!DEMO && <SettingsSheet email={session?.user.email} items={items} />}
      </header>

      <main className="w-full min-w-0 flex-1 space-y-6 px-4 pb-32 pt-2 md:pb-16 md:pt-4">
        {tab === "week" && (
          <>
            <ThisWeek items={items} onSelect={setSelected} />
            <PlanDay />
          </>
        )}
        {tab === "calendar" && (
          <CalendarMonth items={items} onSelect={setSelected} />
        )}
        {tab === "library" && <Library items={items} onSelect={setSelected} />}
        {tab === "did" && <WeDidGo items={items} onSelect={setSelected} />}
      </main>

      <button
        aria-label="Add"
        onClick={() => setCaptureOpen(true)}
        className="fixed bottom-[calc(4.5rem+env(safe-area-inset-bottom))] right-4 z-50 flex size-14 items-center justify-center rounded-full bg-foreground text-background shadow-lg transition-transform hover:scale-105 active:scale-95 md:bottom-10 md:right-10"
      >
        <Plus className="size-6" strokeWidth={2.2} />
      </button>

      <nav
        className="fixed inset-x-0 bottom-0 z-40 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 md:hidden"
        aria-label="Primary"
      >
        <div className="mx-auto grid w-full max-w-xl grid-cols-4 pb-[env(safe-area-inset-bottom)]">
          {TABS.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              type="button"
              onClick={() => setTab(id)}
              aria-current={tab === id ? "page" : undefined}
              className={cn(
                "relative flex flex-col items-center gap-0.5 whitespace-nowrap py-2.5 text-[11px]",
                tab === id ? "text-foreground" : "text-muted-foreground",
              )}
            >
              <Icon className="size-5" strokeWidth={tab === id ? 2.4 : 1.8} />
              {label}
            </button>
          ))}
        </div>
      </nav>

      <Drawer open={captureOpen} onOpenChange={setCaptureOpen}>
        <DrawerContent className="max-h-[92dvh]">
          <div className="mx-auto w-full min-w-0 max-w-lg overscroll-contain overflow-x-hidden overflow-y-auto px-4 pb-8 scroll-pb-[40dvh]">
            <DrawerHeader className="px-0">
              <DrawerTitle className="text-left">Add something</DrawerTitle>
            </DrawerHeader>
            <Capture
              onCreated={(item) => {
                setCaptureOpen(false);
                refresh();
                setSelected(item);
              }}
            />
          </div>
        </DrawerContent>
      </Drawer>

      <ItemSheet
        item={selected}
        allItems={items}
        members={members}
        onClose={() => setSelected(null)}
        onChanged={refresh}
        onSwitch={setSelected}
      />
      <DigestSheet digestId={digestId} onClose={() => setDigestId(null)} />
      <Toaster
        position="top-center"
        offset="calc(1rem + env(safe-area-inset-top))"
      />
    </div>
  );
}
