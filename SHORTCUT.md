# iOS share-sheet capture

Two small Shortcuts give you one-tap capture from Safari, Instagram, WhatsApp —
anywhere with a share sheet. Both POST to the `ingest` edge function, which
parses with AI and saves the result directly to the app's shared library.

- **Endpoint:** `https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/ingest`
- **Ingest secret:** the `INGEST_SECRET` value — print it on the laptop with:

  ```sh
  grep INGEST_SECRET ~/Desktop/for-science-and-pleasure/.supabase.env
  ```

- **Feed secret (calendar + digest pull):** prefer `FEED_SECRET` once set.
  Until then, the same `INGEST_SECRET` still works so existing shortcuts and
  calendar subscriptions keep working:

  ```sh
  grep -E 'FEED_SECRET|INGEST_SECRET' ~/Desktop/for-science-and-pleasure/.supabase.env
  ```

Build these once on one phone, then AirDrop the shortcuts to the other phone
(iCloud-share them from the Shortcuts app).

## Shortcut 1 — "Save to S&P" (links & text)

1. Shortcuts app → **+** → rename to `Save to S&P`.
2. Tap the ⓘ info panel → enable **Show in Share Sheet** → under *Receive*,
   select **URLs, Text, and Safari web pages**.
3. Add action **Get Contents of URL** and configure:
   - URL: the endpoint above
   - Method: **POST**
   - Headers: `x-ingest-secret` → *(the secret)*
   - Request Body: **JSON**, one field:
     - `text` (Text) → **Shortcut Input** (as Text)
4. (Optional) add **Show Notification** with the result so you get a "Saved ✓".

## Shortcut 2 — "Screenshot to S&P" (Instagram etc.)

For Instagram posts: screenshot the post, then share the screenshot to this
shortcut (or share the post's link with Shortcut 1 and it saves without dates —
the screenshot version reads the dates off the image).

1. New shortcut `Screenshot to S&P`, **Show in Share Sheet**, *Receive*:
   **Images**.
2. Action **Base64 Encode** → input: **Shortcut Input**, line breaks: **None**.
3. Action **Get Contents of URL**:
   - URL: the endpoint, Method **POST**
   - Header: `x-ingest-secret` → *(the secret)*
   - JSON body, two fields:
     - `image_base64` (Text) → **Base64 Encoded** (the previous action's output)
     - `image_media_type` (Text) → `image/png`
4. (Optional) **Show Notification** with the result.

Tip: you can also add `added_by` (Text) → your email in either body, so cards
show who dumped them.

## Automation — Sunday-evening digest

A weekly "here's your week" note written by Claude, delivered as a notification.
Each of you sets this up once:

1. Shortcuts app → **Automation** tab → **+** → **Time of Day** → Sunday, 6:00 PM
   → *Run Immediately*.
2. Action **Get Contents of URL**:
   - `https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/digest?key=`*(FEED_SECRET, or INGEST_SECRET until FEED_SECRET is set)*
3. Action **Get Dictionary Value** → key `text` → from *Contents of URL*.
4. Action **Show Notification** → body: the *Dictionary Value*.

## Subscribe your real calendars

One shared feed keeps opening/closing markers inside
Google Calendar automatically — no per-item exporting:

- Feed URL: `https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/calendar?key=`*(FEED_SECRET, or INGEST_SECRET until FEED_SECRET is set)*
- **Google Calendar** (do this on the web at calendar.google.com): Settings →
  *Add calendar* → *From URL* → paste the feed URL. It then syncs to the
  Google Calendar app on both phones signed into that account (Google refreshes
  external feeds every few hours).
