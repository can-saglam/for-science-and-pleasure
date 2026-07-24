// calendar: subscribable ICS feed of the shared library. Add it once to
// Google/Apple Calendar and opening/closing markers stay in sync automatically.
// Auth via ?key= (calendar apps need URL-embedded auth). Prefer FEED_SECRET;
// falls back to INGEST_SECRET until FEED_SECRET is configured.
import { createClient } from "npm:@supabase/supabase-js@2";
import { isFeedKeyAuthorized } from "../_shared/auth.ts";

function icsEscape(s: string): string {
  return s.replace(/([,;\\])/g, "\\$1");
}

function allDay(uid: string, date: string, summary: string, url?: string | null): string {
  const dt = date.replace(/-/g, "");
  const next = new Date(new Date(date + "T00:00:00Z").getTime() + 86400000)
    .toISOString()
    .slice(0, 10)
    .replace(/-/g, "");
  return [
    "BEGIN:VEVENT",
    `UID:${uid}@fsap`,
    `DTSTART;VALUE=DATE:${dt}`,
    `DTEND;VALUE=DATE:${next}`,
    `SUMMARY:${icsEscape(summary)}`,
    url ? `URL:${url}` : "",
    "TRANSP:TRANSPARENT",
    "END:VEVENT",
  ]
    .filter(Boolean)
    .join("\r\n");
}

Deno.serve(async (req) => {
  const key = new URL(req.url).searchParams.get("key");
  if (!isFeedKeyAuthorized(key)) {
    return new Response("unauthorized", { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: items, error } = await supabase
    .from("items")
    .select("id, kind, status, title, starts_on, ends_on, url")
    .is("deleted_at", null)
    .in("status", ["saved", "planned"]);
  if (error) return new Response(String(error.message), { status: 500 });

  const events: string[] = [];
  for (const i of items ?? []) {
    if (i.kind === "event" && i.ends_on) {
      events.push(allDay(`close-${i.id}`, i.ends_on, `Last day — ${i.title}`, i.url));
    }
    if (i.kind === "event" && i.starts_on && i.starts_on !== i.ends_on) {
      events.push(allDay(`open-${i.id}`, i.starts_on, `Opens — ${i.title}`, i.url));
    }
  }

  const body = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Can We Go?//EN",
    "X-WR-CALNAME:Can We Go?",
    "X-WR-TIMEZONE:Europe/London",
    ...events,
    "END:VCALENDAR",
  ].join("\r\n");

  return new Response(body, {
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Cache-Control": "max-age=300",
    },
  });
});
