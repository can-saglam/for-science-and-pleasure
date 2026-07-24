# Can We Go?

A shared London events-and-places app for two. Dump links from anywhere, AI
parses them into cards with opening/closing dates, and a calendar + "This Week"
view helps plan the week around what's opening and closing.

**Live app:** https://can-saglam.github.io/for-science-and-pleasure/
(add it to your home screen — Share → *Add to Home Screen*)

## How it works

- **Capture** — paste a link/text (or attach a screenshot for Instagram) in the
  Add tab, or share from any app via the iOS Shortcut (see
  [SHORTCUT.md](SHORTCUT.md)). Claude parses out title, venue, area, dates,
  category, and price, then saves it directly to the shared library.
- **Library** — the shared pool. Events carry a window (`opens`/`closes`) and
  get *closing soon* / *last chance* badges; places are evergreen.
- **Calendar** — month view where event runs render as span bars.
- **This Week** — what's closing, what's opening, plus a
  rotating shortlist of saved places.
- *Add to Calendar* exports an event's opening date as an `.ics`, or subscribe
  to the live feed (see below).
- **Live sync** — changes appear on both phones instantly (Supabase realtime).
- **Make a day of it** — event pages suggest saved places nearby (geocoded at
  parse time; real walking distance when coordinates are known, area-name match
  otherwise), with Google Maps links and walking directions.
- **Plan a day** — "Free on a day?" on This Week asks Claude to build 1–3 day
  ideas from your own list, prioritising things that close soon.
- **Calendar feed** — `/functions/v1/calendar?key=…` is a subscribable ICS
  ("Opens —" and "Last day —" markers) for Google Calendar.
- **Weekly heads-up** — opt in from the bell in the app to receive a short
  Claude-written push notification at 10am every Tuesday. Tapping it opens the
  same persisted digest inside the PWA. On iPhone, notifications require the
  Home Screen app.
- **We Did Go** — Done items and *Missed* events (ended before you made it);
  duplicate URLs are deduped on capture.

## Stack

- `web/` — React + Vite + Tailwind v4 + shadcn/ui (monochrome), installable PWA.
- Supabase project `gvewzvcvmeztqyfwkgwa` (London) — Postgres + email/password
  auth + edge functions. Membership is allow-listed in `public.members`; anyone
  else who signs in sees nothing (RLS).
- Edge functions include `parse` (authenticated, used by the app), `ingest`
  (secret-header endpoint used by the iOS Shortcut), `locate` (authenticated;
  proposes venue/area/coordinates for saves missing them — Settings → Missing
  locations, applied only after in-app confirmation), and `send-digest`
  (Vault-authenticated Tuesday Web Push delivery). Claude and VAPID credentials
  are stored as Supabase secrets.

## Development

```sh
cd web && npm run dev
```

Secrets (DB password, ingest/feed secrets, keys) live in `.supabase.env` (not in
git). Supabase CLI is linked: `supabase db push`, `supabase functions deploy`,
`supabase config push`.

- `INGEST_SECRET` — iOS Shortcut header for `/functions/v1/ingest` only.
- `FEED_SECRET` — optional dedicated key for `/calendar` and `/digest` URL
  feeds. Until it is set, those endpoints still accept `INGEST_SECRET` so
  existing calendar subscriptions keep working. After you set `FEED_SECRET`,
  update the calendar/digest URLs to use it.

## Deploy

```sh
cd web && npm run build && npx gh-pages -d dist
```

## Adding a member

```sql
insert into public.members (email, display_name) values ('email@example.com', 'Name');
```

Run it in the Supabase SQL editor (or via a migration).
