import { useCallback, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { fetchItems } from "@/lib/api";
import type { Item } from "@/lib/types";
import { Auth } from "@/components/Auth";
import { Capture } from "@/components/Capture";
import { Inbox } from "@/components/Inbox";
import { Library } from "@/components/Library";
import { CalendarMonth } from "@/components/CalendarMonth";
import { ThisWeek } from "@/components/ThisWeek";
import { ItemSheet } from "@/components/ItemSheet";
import { Toaster } from "@/components/ui/sonner";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import {
  CalendarDays,
  LibraryBig,
  LogOut,
  Plus,
  Sparkles,
} from "lucide-react";

import { DEMO_ITEMS } from "@/lib/demo";

const DEMO = new URLSearchParams(window.location.search).has("demo");

type Tab = "week" | "calendar" | "add" | "library";

const TABS: { id: Tab; label: string; icon: React.ElementType }[] = [
  { id: "week", label: "This Week", icon: Sparkles },
  { id: "calendar", label: "Calendar", icon: CalendarDays },
  { id: "add", label: "Add", icon: Plus },
  { id: "library", label: "Library", icon: LibraryBig },
];

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [items, setItems] = useState<Item[]>([]);
  const [tab, setTab] = useState<Tab>("week");
  const [selected, setSelected] = useState<Item | null>(null);

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
    const onFocus = () => refresh();
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onFocus);
    return () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onFocus);
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

      <main className="flex-1 space-y-6 px-4 pb-28 pt-2">
        {tab === "week" && (
          <>
            <Inbox items={items} onSelect={setSelected} />
            <ThisWeek items={items} onSelect={setSelected} />
          </>
        )}
        {tab === "calendar" && (
          <CalendarMonth items={items} onSelect={setSelected} />
        )}
        {tab === "add" && (
          <Capture
            onCreated={(item) => {
              refresh();
              setSelected(item);
            }}
          />
        )}
        {tab === "library" && <Library items={items} onSelect={setSelected} />}
      </main>

      <nav className="fixed inset-x-0 bottom-0 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80">
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
              {id === "week" && inboxCount > 0 && (
                <span className="absolute right-[22%] top-1.5 flex size-4 items-center justify-center rounded-full bg-foreground text-[9px] font-semibold text-background">
                  {inboxCount}
                </span>
              )}
            </button>
          ))}
        </div>
      </nav>

      <ItemSheet
        item={selected}
        onClose={() => setSelected(null)}
        onChanged={refresh}
      />
      <Toaster position="top-center" />
    </div>
  );
}
