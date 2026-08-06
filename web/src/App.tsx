import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { fetchItems, fetchMembers } from "@/lib/api";
import { useIsDark } from "@/lib/theme";
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
  ArrowLeft,
  CalendarDays,
  Footprints,
  LibraryBig,
  Loader2,
  MapPin,
  Palette,
  Plus,
} from "lucide-react";
import { toast } from "sonner";

const DEMO = new URLSearchParams(window.location.search).has("demo");
const INITIAL_DIGEST = new URLSearchParams(window.location.search).has("digest");
const INITIAL_ITEM = new URLSearchParams(window.location.search).get("item");

// Last successful fetch, so the app opens with content offline / instantly.
const ITEMS_CACHE_KEY = "cwg-items";

function readItemsCache(): Item[] {
  if (DEMO) return [];
  try {
    return JSON.parse(localStorage.getItem(ITEMS_CACHE_KEY) ?? "[]") as Item[];
  } catch {
    return [];
  }
}

type Tab = "week" | "places" | "library" | "did";

const TABS: { id: Tab; label: string; icon: React.ElementType }[] = [
  { id: "week", label: "This Week", icon: Palette },
  { id: "places", label: "Places", icon: MapPin },
  { id: "library", label: "Library", icon: LibraryBig },
  { id: "did", label: "We Did Go", icon: Footprints },
];

export default function App() {
  // Subscribing here re-renders the whole tree when the theme flips, so
  // card tints (computed in render from the .dark class) stay in sync.
  const isDark = useIsDark();
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [items, setItems] = useState<Item[]>(readItemsCache);
  const [tab, setTab] = useState<Tab>("week");
  const [calendarOpen, setCalendarOpen] = useState(false);
  const [selected, setSelected] = useState<Item | null>(null);
  const [captureOpen, setCaptureOpen] = useState(false);
  const [members, setMembers] = useState<Member[]>([]);
  const [digestOpen, setDigestOpen] = useState(INITIAL_DIGEST);
  // From a "X added: …" notification tap; opened once items are loaded.
  const [pendingItemId, setPendingItemId] = useState<string | null>(INITIAL_ITEM);
  const hasLoadedItems = useRef(false);

  // Each view is its own page: start it at the top. Without this the old
  // tab's scroll offset carries over and the sticky bars land mid-"stuck",
  // so everything appears to jump. (Layout effect: before paint, no flash.)
  useLayoutEffect(() => {
    window.scrollTo(0, 0);
  }, [tab, calendarOpen]);

  useEffect(() => {
    if (!pendingItemId) return;
    const item = items.find((i) => i.id === pendingItemId);
    if (item) {
      setSelected(item);
      setPendingItemId(null);
    }
  }, [pendingItemId, items]);

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
      const fresh = await fetchItems();
      setItems(fresh);
      hasLoadedItems.current = true;
      try {
        localStorage.setItem(ITEMS_CACHE_KEY, JSON.stringify(fresh));
      } catch {
        // Storage full or unavailable — the app still works, just not offline.
      }
    } catch {
      // Offline or flaky: keep showing the cached list without nagging.
      if (!hasLoadedItems.current && readItemsCache().length === 0) {
        toast.error("Couldn't load your list. Try again in a moment.");
      }
    }
  }, []);

  useEffect(() => {
    if (DEMO) setItems(DEMO_ITEMS);
  }, []);

  useEffect(() => {
    if (INITIAL_DIGEST || INITIAL_ITEM) {
      const url = new URL(window.location.href);
      url.searchParams.delete("digest");
      url.searchParams.delete("item");
      window.history.replaceState(null, "", url);
    }

    const onMessage = (event: MessageEvent) => {
      if (event.data?.type === "OPEN_DIGEST") {
        setDigestOpen(true);
      }
      if (event.data?.type === "NOTIFICATION_TAP" && typeof event.data.url === "string") {
        const tapped = new URL(event.data.url, window.location.href);
        if (tapped.searchParams.has("digest")) setDigestOpen(true);
        const itemId = tapped.searchParams.get("item");
        if (itemId) setPendingItemId(itemId);
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

  const openTab = (id: Tab) => {
    setCalendarOpen(false);
    setTab(id);
  };
  // The calendar isn't a tab: it's a full-page view reachable from the
  // header on This Week and Library (where dates are on your mind).
  const showCalendarButton = calendarOpen || tab === "week" || tab === "library";

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
              onClick={() => openTab(id)}
              aria-current={tab === id && !calendarOpen ? "page" : undefined}
              className={cn(
                "relative rounded-full px-4 py-1.5 text-sm transition-colors",
                tab === id && !calendarOpen
                  ? "bg-foreground text-background"
                  : "text-muted-foreground hover:bg-accent hover:text-foreground",
              )}
            >
              {label}
            </button>
          ))}
        </nav>
        <div className="flex shrink-0 items-center">
          {/* invisible (not unmounted) on tabs without it, so the gear icon
              doesn't slide sideways every time the tab changes */}
          <button
            type="button"
            aria-label={calendarOpen ? "Close calendar" : "Calendar"}
            title="Calendar"
            aria-pressed={calendarOpen}
            aria-hidden={!showCalendarButton}
            tabIndex={showCalendarButton ? undefined : -1}
            onClick={() => setCalendarOpen((o) => !o)}
            className={cn(
              "flex size-9 items-center justify-center rounded-md transition-colors",
              !showCalendarButton && "invisible",
              calendarOpen
                ? "bg-foreground text-background"
                : "text-muted-foreground hover:bg-accent hover:text-foreground",
            )}
          >
            <CalendarDays className="size-4" />
          </button>
          {!DEMO && (
            <SettingsSheet
              email={session?.user.email}
              items={items}
              onOpenDigest={() => setDigestOpen(true)}
            />
          )}
        </div>
      </header>

      <main className="w-full min-w-0 flex-1 space-y-6 px-4 pb-32 pt-2 md:pb-16 md:pt-4">
        {calendarOpen ? (
          <>
            <button
              type="button"
              onClick={() => setCalendarOpen(false)}
              className="flex items-center gap-1.5 text-sm text-muted-foreground transition-colors hover:text-foreground"
            >
              <ArrowLeft className="size-4" />
              Back to {TABS.find((t) => t.id === tab)?.label}
            </button>
            <CalendarMonth items={items} onSelect={setSelected} />
          </>
        ) : (
          <>
            {tab === "week" && (
              <>
                <ThisWeek items={items} onSelect={setSelected} />
                <PlanDay />
              </>
            )}
            {tab === "places" && (
              <Library
                kind="place"
                items={items}
                members={members}
                onSelect={setSelected}
              />
            )}
            {tab === "library" && (
              <Library
                kind="event"
                items={items}
                members={members}
                onSelect={setSelected}
              />
            )}
            {tab === "did" && <WeDidGo items={items} onSelect={setSelected} />}
          </>
        )}
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
          {TABS.map(({ id, label, icon: Icon }) => {
            const current = tab === id && !calendarOpen;
            return (
              <button
                key={id}
                type="button"
                onClick={() => openTab(id)}
                aria-current={current ? "page" : undefined}
                className={cn(
                  "relative flex flex-col items-center gap-0.5 whitespace-nowrap py-2.5 text-[11px]",
                  current ? "text-foreground" : "text-muted-foreground",
                )}
              >
                <Icon className="size-5" strokeWidth={current ? 2.4 : 1.8} />
                {label}
              </button>
            );
          })}
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
              onSaved={() => {
                setCaptureOpen(false);
                refresh();
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
      <DigestSheet
        open={digestOpen}
        items={items}
        onSelect={(item) => {
          setDigestOpen(false);
          setSelected(item);
        }}
        onClose={() => setDigestOpen(false)}
      />
      <Toaster
        theme={isDark ? "dark" : "light"}
        position="top-center"
        offset="calc(1rem + env(safe-area-inset-top))"
      />
    </div>
  );
}
