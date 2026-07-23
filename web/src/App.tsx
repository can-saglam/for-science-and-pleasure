import { useCallback, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { fetchItems, fetchMembers } from "@/lib/api";
import type { Item, Member } from "@/lib/types";
import { PlanDay } from "@/components/PlanDay";
import { Auth } from "@/components/Auth";
import { Capture } from "@/components/Capture";
import { Inbox } from "@/components/Inbox";
import { Library } from "@/components/Library";
import { CalendarMonth } from "@/components/CalendarMonth";
import { ThisWeek } from "@/components/ThisWeek";
import { ItemSheet } from "@/components/ItemSheet";
import { Toaster } from "@/components/ui/sonner";
import { Button } from "@/components/ui/button";
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
  Inbox as InboxIcon,
  LibraryBig,
  LogOut,
  Plus,
  Sparkles,
} from "lucide-react";

const DEMO = new URLSearchParams(window.location.search).has("demo");

type Tab = "week" | "calendar" | "inbox" | "library";

const TABS: { id: Tab; label: string; icon: React.ElementType }[] = [
  { id: "week", label: "This Week", icon: Sparkles },
  { id: "calendar", label: "Calendar", icon: CalendarDays },
  { id: "inbox", label: "Inbox", icon: InboxIcon },
  { id: "library", label: "Library", icon: LibraryBig },
];

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [items, setItems] = useState<Item[]>([]);
  const [tab, setTab] = useState<Tab>("week");
  const [selected, setSelected] = useState<Item | null>(null);
  const [captureOpen, setCaptureOpen] = useState(false);
  const [members, setMembers] = useState<Member[]>([]);

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
      return;
    }
    try {
      setItems(await fetchItems());
    } catch {
      // ignore transient fetch errors (e.g. token refresh in flight)
    }
  }, []);

  useEffect(() => {
    if (DEMO) setItems(DEMO_ITEMS);
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
    if (!authReady) return null;
    if (!session) return <Auth />;
  }

  const inboxCount = items.filter((i) => i.status === "inbox").length;

  return (
    <div className="mx-auto flex min-h-dvh max-w-xl flex-col">
      <header className="flex items-center justify-between px-4 pb-2 pt-5">
        <h1 className="font-heading text-xl font-semibold tracking-tight">
          For Science and Pleasure
        </h1>
        <Button
          variant="ghost"
          size="icon"
          className="text-muted-foreground"
          onClick={() => supabase.auth.signOut()}
        >
          <LogOut />
        </Button>
      </header>

      <main className="flex-1 space-y-6 px-4 pb-32 pt-2">
        {tab === "week" && (
          <>
            <ThisWeek items={items} onSelect={setSelected} />
            <PlanDay items={items} onChanged={refresh} />
          </>
        )}
        {tab === "calendar" && (
          <CalendarMonth items={items} onSelect={setSelected} />
        )}
        {tab === "inbox" && <Inbox items={items} onSelect={setSelected} />}
        {tab === "library" && <Library items={items} onSelect={setSelected} />}
      </main>

      <button
        aria-label="Add"
        onClick={() => setCaptureOpen(true)}
        className="fixed bottom-[calc(4.5rem+env(safe-area-inset-bottom))] right-4 z-50 flex size-14 items-center justify-center rounded-full bg-foreground text-background shadow-lg transition-transform active:scale-95"
      >
        <Plus className="size-6" strokeWidth={2.2} />
      </button>

      <nav className="fixed inset-x-0 bottom-0 z-40 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80">
        <div className="mx-auto grid max-w-xl grid-cols-4 pb-[env(safe-area-inset-bottom)]">
          {TABS.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              onClick={() => setTab(id)}
              className={cn(
                "relative flex flex-col items-center gap-0.5 py-2.5 text-[11px]",
                tab === id ? "text-foreground" : "text-muted-foreground",
              )}
            >
              <Icon className="size-5" strokeWidth={tab === id ? 2.4 : 1.8} />
              {label}
              {id === "inbox" && inboxCount > 0 && (
                <span className="absolute right-[22%] top-1.5 flex size-4 items-center justify-center rounded-full bg-foreground text-[9px] font-semibold text-background">
                  {inboxCount}
                </span>
              )}
            </button>
          ))}
        </div>
      </nav>

      <Drawer open={captureOpen} onOpenChange={setCaptureOpen}>
        <DrawerContent className="max-h-[92dvh]">
          <div className="overflow-y-auto px-4 pb-8">
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
      <Toaster position="top-center" />
    </div>
  );
}
