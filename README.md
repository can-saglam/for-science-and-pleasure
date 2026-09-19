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
- **Remind** — one opt-in reminder per save, shared with the group. Dated
  events offer presets that fire at 10:00 in the home city (a week / 3 days
  / 1 day / morning of start or close); any save, places included, can take
  a hand-picked day and time instead. Tapping the push opens the card.
- **Widget** — home-screen widget rotating through saved events, hourly.
- **Live sync** — changes appear on both phones via Supabase; duplicate URLs
  are deduped on capture.

## Stack

- `ios/` — SwiftUI + SwiftData app, share extension, WidgetKit extension.
  See [ios/README.md](ios/README.md) for setup (Secrets.plist etc.).
- Supabase project `gvewzvcvmeztqyfwkgwa` (London) — Postgres + email OTP
  auth + edge functions. Membership is allow-listed in `public.members`;
  anyone else who signs in sees nothing (RLS).
- Edge functions: `parse` and `locate` (used by the app; `locate` proposes
  venue/area/coordinates for saves missing them, applied only after in-app
  confirmation), `suggest`, `notify-save`, `group-membership`,
  `delete-account`, `send-reminders` (shared Remind pushes: presets at 10:00
  home time, hand-picked times as they come round), and `calendar` (the ICS
  feed). Claude and push credentials are stored as Supabase secrets.
- The only ways in are the app and its share extension, both with a
  signed-in session. The old Shortcut write path (`ingest`) and the
  Sunday digest pull (`digest`) were removed in September 2026; proper
  App Intents / Shortcuts actions are a later phase.

## Calendar subscription

One shared feed keeps opening/closing markers inside Google Calendar
automatically, no per-item exporting:

- Feed URL: `https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/calendar?key=`*(your group's feed token)*
- Google Calendar (on the web at calendar.google.com): Settings → *Add
  calendar* → *From URL* → paste the feed URL. It then syncs to the Google
  Calendar app on every phone signed into that account (Google refreshes
  external feeds every few hours).

## Development

Secrets (DB password, feed secret, keys) live in `.supabase.env` (not in
git). Supabase CLI is linked: `supabase db push`, `supabase functions
deploy`, `supabase config push`.

- `FEED_SECRET` — dedicated key for the `/calendar` feed of the founding
  group. Per-group feeds use each group's `feed_token`.
  Parse, locate, suggest, notify-save, group-membership and delete-account
  require a signed-in user JWT.

## Adding a member

```sql
insert into public.members (email, display_name) values ('email@example.com', 'Name');
```

Run it in the Supabase SQL editor (or via a migration).
