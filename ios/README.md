# Can We Go? — iOS

Native SwiftUI app. Phase 1: SwiftData models with CloudKit sync, the four
tabs (This Week / Places / Library / We Did Go), item detail, and a one-off
import from the web app's Supabase data.

## First run

1. Open `ios/CanWeGo.xcodeproj` in Xcode.
2. Pick your team under *Signing & Capabilities* for **both** targets —
   the app and the **CanWeGoShare** share extension. Signing is automatic;
   Xcode registers the app ID, the iCloud container
   (`iCloud.com.cansaglam.CanWeGo`), and the App Group
   (`group.com.cansaglam.CanWeGo`) on first build.
3. Optional — seed your existing saves (do this for **one** device only;
   CloudKit sync distributes them to the rest):

   ```sh
   deno run --allow-read --allow-write --allow-net scripts/export-items.ts
   ```

   This writes `ios/CanWeGo/Resources/seed-items.json` (gitignored — it's
   personal data and the repo is public). The app imports it on first launch
   if its store is empty.
4. The capture flow ("+" button) calls the Supabase `parse` edge function,
   authenticated with the ingest secret. It reads
   `ios/CanWeGo/Resources/Secrets.plist` (gitignored) — copy
   `Secrets.example.plist` and fill in the values from `.supabase.env`.
   Already generated on this machine.
5. Build & run. On a simulator without an iCloud account the app silently
   falls back to a local-only store — sign into iCloud in the simulator's
   Settings (or run on your phone) to get sync.

## Architecture notes

- **Data**: SwiftData + CloudKit private database. Every model property has
  a default and nothing is unique-constrained (CloudKit requirements).
  Dates-without-times are `yyyy-MM-dd` strings, same as the web app.
- **Domain logic** (time buckets, urgency, accent palette) is ported from
  `web/src/lib/api.ts` / `colors.ts` — keep the two in sync when rules change.
- **Share extension** (`ShareExtension/`): share a link, text, or image
  from any app → it's parsed and previewed right in the share sheet. Saves
  are dropped as JSON into the App Group container; the app sweeps them
  into SwiftData (and CloudKit) next time it comes to the foreground —
  extensions can't safely write to the synced store themselves.
- **Not yet here** (later phases): CKShare household sharing, widgets,
  digest local notification.
