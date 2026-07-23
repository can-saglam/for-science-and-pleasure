# For Science and Pleasure

A shared London events-and-places app for two. Dump links from anywhere, AI
parses them into cards with opening/closing dates, and a calendar + "This Week"
view helps plan the week around what's opening and closing.

**Live app:** https://can-saglam.github.io/for-science-and-pleasure/
(add it to your home screen — Share → *Add to Home Screen*)

## How it works

- **Capture** — paste a link/text (or attach a screenshot for Instagram) in the
  Add tab, or share from any app via the iOS Shortcut (see
  [SHORTCUT.md](SHORTCUT.md)). Claude parses out title, venue, area, dates,
  category, price. Everything lands in the **Inbox** for a quick confirm.
- **Library** — the shared pool. Events carry a window (`opens`/`closes`) and
  get *closing soon* / *last chance* badges; places are evergreen.
- **Calendar** — month view where event runs render as span bars.
- **This Week** — planned outings, what's closing, what's opening, plus a
  rotating shortlist of saved places.
- Planning is a soft `planned for` date; *Add to Calendar* exports an `.ics`
  for the ones you commit to — or subscribe to the live feed (see below).
- **Live sync** — changes appear on both phones instantly (Supabase realtime).
- **Make a day of it** — event pages suggest saved places nearby (geocoded at
  parse time; real walking distance when coordinates are known, area-name match
  otherwise), with Google Maps links and walking directions.
- **Plan a day** — "Free on a day?" on This Week asks Claude to build 1–3 day
  plans from your own list, prioritising things that close soon; one tap plans
  the whole thing.
- **Calendar feed** — `/functions/v1/calendar?key=…` is a subscribable ICS
  (planned days, "Opens —", "Last day —" markers) for Google Calendar.
- **Weekly digest** — `/functions/v1/digest?key=…` returns a short
  Claude-written summary of the week; wire it to a Sunday Shortcut automation
  (see SHORTCUT.md).
- **History** — the Library keeps Done and *Missed* (ended before you made it)
  in a separate tab; duplicate URLs are deduped on capture.

## Stack

- `web/` — React + Vite + Tailwind v4 + shadcn/ui (monochrome), installable PWA.
- Supabase project `gvewzvcvmeztqyfwkgwa` (London) — Postgres + magic-link
  auth + edge functions. Membership is allow-listed in `public.members`; anyone
  else who signs in sees nothing (RLS).
- Edge functions: `parse` (authenticated, used by the app) and `ingest`
  (secret-header endpoint used by the iOS Shortcut). Both call Claude
  (`ANTHROPIC_API_KEY` is a Supabase secret) with structured outputs.

## Development

```sh
cd web && npm run dev
```

Secrets (DB password, ingest secret, keys) live in `.supabase.env` (not in
git). Supabase CLI is linked: `supabase db push`, `supabase functions deploy`,
`supabase config push`.

## Deploy

```sh
cd web && npm run build && npx gh-pages -d dist
```

## Adding a member

```sql
insert into public.members (email, display_name) values ('email@example.com', 'Name');
```

Run it in the Supabase SQL editor (or via a migration).
