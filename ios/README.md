# Can We Go? — iOS

Native SwiftUI app with a share extension and a widget extension. SwiftData
holds the library on the phone; Supabase is the one source of truth, synced
both ways.

## First run

1. Open `ios/CanWeGo.xcodeproj` in Xcode. Signing is automatic for the app,
   **ShareExtension** and **WidgetExtension** targets; they share the App
   Group `group.com.cansaglam.CanWeGo`.
2. Copy `CanWeGo/Resources/Secrets.example.plist` to `Secrets.plist` beside
   it (gitignored) and fill in `SUPABASE_URL`.
3. Build and run, and sign in with Apple. The first sync pulls your group's
   library.

For screenshot runs without an account, launch with `CWG_SKIP_AUTH=1`: the
app runs on local demo data from `CanWeGo/Resources/seed-items.json`
(gitignored, personal; written by `scripts/export-items.ts`). Its store is
local to the simulator; nothing syncs.

## Releasing

`scripts/release.sh` makes a TestFlight build from a clean `main` that matches
GitHub: the next build number in every target, a `Build N` commit tagged
`build-N`, pushed, then an archive opened in the Organizer for Distribute App
→ App Store Connect. `scripts/screenshots.sh` photographs every screen the app
can be launched into.

## Tests

- `swift test --package-path ios`: the sync merge rules (`CanWeGo/SyncCore`),
  on the Mac, no simulator.
- The `CanWeGoIntentTests` scheme: Siri, Shortcuts and Spotlight
  (`AppIntentsTesting`) against the installed app, so install a fresh build
  on the simulator first.

## Architecture notes

- **Sync** (`Support/SupabaseSync.swift`): each phone remembers every save as
  the server last had it. Pushes send only the columns changed since then
  (whole rows only for new saves); pulls take the server's columns except
  ones with an edit not yet sent, so two people changing different things on
  one save both keep their change. Pulls fetch rows changed since the last
  one (`items.touched_at`), with a full pull once a day that also drops saves
  the server no longer has. The server's stale-write guard and the edit
  rules live in the migrations.
- **Library ownership**: the store belongs to the account and group that
  last pulled it. When that changes, sync pushes this person's own unsent
  edits, wipes, and pulls the new library; nothing else deletes the store.
- **Store** (`CanWeGoApp.swift`, `Models/LibrarySchema.swift`): a versioned
  SwiftData schema, local only (no iCloud mirror). A store is set aside
  (Application Support/Set aside) only when SQLite calls it damaged or it was
  written for another model; any other failure to open runs that launch on
  an empty stand-in that syncs and mirrors nothing.
- **Dates** without times are `yyyy-MM-dd` strings on the home city's
  calendar, as on the server.
- **Share extension** (`ShareExtension/`): parses and previews in the share
  sheet, then drops the save as JSON into the App Group inbox; the app sweeps
  it into the library next time it's in front.
- **Widget** (`WidgetExtension/`) reads a snapshot the app writes to the App
  Group (`Support/WidgetStore.swift`).
