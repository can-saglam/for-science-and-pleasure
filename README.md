# Can We Go?

A shared events-and-places app for you and your people (solo, or a group of
up to four). Save links, screenshots or a sentence from anywhere; Claude
reads them into cards with opening and closing dates, and the app helps plan
around what's on, what's closing and what you've been meaning to try.

The product is the native iOS app in [`ios/`](ios/) (SwiftUI, on
TestFlight; version 1.0). The website is [wegocan.com](https://wegocan.com),
built from [`site/`](site/) and served by Cloudflare Pages: the landing page,
invite and shared-save pages, and the support, privacy and terms pages. The
original web PWA was retired in September 2026; a dormant installed copy
once replayed weeks-old data over the live library, which is why writes are
also guarded server-side (`0013_stale_write_guard.sql`).

## How it works

- **Capture**: paste a link or text, snap a poster, share from any app, or
  ask Siri. Claude parses out title, venue, area, dates, showings, category
  and price into a card you confirm before saving. City picks ("Trending in
  London") open straight into a card.
- **Events and Places**: the shared library. Events carry a window and get
  *closing soon* and *on now* sections; places are evergreen, with a map,
  live opening hours and *Open now*.
- **Plans and reminders**: pick a day to go (with the showing's time), and
  one reminder per save, shared with the group. On the day a Live Activity
  takes over the Lock Screen. The morning after, the app asks how it went.
- **We Did Go**: the journal of done and missed saves, by year and month.
- **Groups**: Sign in with Apple; everyone starts in a group of one and
  invites others by code or wegocan.com link (2 people free, 4 with Plus).
- **Plus**: StoreKit subscription, verified with the App Store Server API.
  Free: 4 saves per category and 10 new saves a day; Plus: no category cap
  and 50 a day.
- **System**: widgets, Siri and Shortcuts, Spotlight, Visual Intelligence,
  Control Center, and iPhone Duo side-by-side layouts.

## Stack

- `ios/`: SwiftUI + SwiftData app, share extension and widget extension. See
  [ios/README.md](ios/README.md).
- Supabase project `gvewzvcvmeztqyfwkgwa` (London): Postgres with row-level
  security scoped to each group, Sign in with Apple, edge functions and cron.
  Migrations in `supabase/migrations/` (with rollbacks in
  `supabase/rollback/`); rehearsal runbook in
  [supabase/tests/README.md](supabase/tests/README.md).
- Edge functions: `parse` (reading saves), `suggestions` and `warm-cities`
  (city picks), `place-photo` and `place-hours` (Google Places),
  `notify-save`, `send-reminders` (reminders and Live Activities),
  `group-membership`, `delete-account`, `record-entitlement` and
  `verify-entitlements` (Plus), `share` (shared saves), `calendar` (the ICS
  feed) and `job-health` (the daily check on every cron job). Claude, Google,
  APNs and App Store credentials are Supabase secrets.
- `site/`: static pages plus Cloudflare Pages functions for invites and
  shared saves. See [site/README.md](site/README.md).

## Calendar subscription

Each group has an ICS feed of its dated saves, so opening and closing days
show up in any calendar app:

- Feed URL: `https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/calendar?key=`*(the group's feed token)*.
  The token is `groups.feed_token` (the app doesn't show it yet) and rotates
  when a member leaves.

## Development

Secrets live outside git: `.supabase.env`, `ios/CanWeGo/Resources/Secrets.plist`
and the App Store keys. The Supabase CLI is linked to the project.

- Tests: `deno test --allow-env --allow-read supabase/functions/_shared/`
  (edge functions) and `swift test --package-path ios` (the sync merge
  rules). CI runs both, plus a type-check of every function against
  `deno.lock`.
- Database: `supabase db push`. Schema changes that touch security, drop
  things or add `NOT NULL` columns are rehearsed on a throwaway copy first.
- Functions: `scripts/deploy-functions.sh [name…]` deploys from a clean
  `main` that matches GitHub, after the type-check and tests, and tags what
  went live.
- TestFlight: `ios/scripts/release.sh` bumps the build number in every
  target, commits and tags `build-N`, pushes, archives and opens the
  Organizer for the upload.
- Site: `node site/build.mjs`, then deploy `site/dist` with Wrangler (see
  [site/README.md](site/README.md)).
