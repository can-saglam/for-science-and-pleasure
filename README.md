# Can We Go?

A shared London events-and-places app for two. Dump links from anywhere, AI
parses them into cards with opening/closing dates, and the app helps plan the
week around what's opening and closing.

The product is the native iOS app in [`ios/`](ios/) (SwiftUI, distributed via
TestFlight). The original web PWA was retired in September 2026: the GitHub
Pages site is down and the `web/` folder removed. Retirement note: a dormant
installed copy once replayed weeks-old cached data over the live library, so
writes are now also guarded server-side (`0013_stale_write_guard.sql`).

## How it works

- **Capture** — paste a link/text, snap a poster, or share from any app via
  the share extension. Claude parses out title, venue, area, dates, category,
  and price into a card you confirm before saving.
- **Events & Places** — the shared library. Events carry a window
  (`opens`/`closes`) and get *last chance* / *closing soon* sections; places
  are evergreen, with a map view and live location.
- **This Week** — what's happening, opening, and closing around the calendar
  week, plus what's simply on.
- **We Did Go** — the journal of done items and *Missed* events, grouped by
  month.
- **Weekend digest** — a push notification previewing the weekend (default
  Thursday morning), plus last-chance nudges for events entering their final
  week.
- **Widget** — home-screen widget rotating through saved events, hourly.
- **Live sync** — changes appear on both phones via Supabase; duplicate URLs
  are deduped on capture.

## Stack

- `ios/` — SwiftUI + SwiftData app, share extension, WidgetKit extension.
  See [ios/README.md](ios/README.md) for setup (Secrets.plist etc.).
- Supabase project `gvewzvcvmeztqyfwkgwa` (London) — Postgres + email OTP
  auth + edge functions. Membership is allow-listed in `public.members`;
  anyone else who signs in sees nothing (RLS).
- Edge functions include `parse` (authenticated, used by the app), `ingest`
  (secret-header endpoint for shares), `locate` (proposes venue/area/
  coordinates for saves missing them, applied only after in-app
  confirmation), and `send-digest` / `digest` (scheduled digest delivery).
  Claude and push credentials are stored as Supabase secrets.

## Development

Secrets (DB password, ingest/feed secrets, keys) live in `.supabase.env` (not
in git). Supabase CLI is linked: `supabase db push`, `supabase functions
deploy`, `supabase config push`.

- `INGEST_SECRET` — secret header for `/functions/v1/ingest` only.
- `FEED_SECRET` — optional dedicated key for `/calendar` and `/digest` URL
  feeds. Until it is set, those endpoints still accept `INGEST_SECRET` so
  existing calendar subscriptions keep working.

## Adding a member

```sql
insert into public.members (email, display_name) values ('email@example.com', 'Name');
```

Run it in the Supabase SQL editor (or via a migration).
