# iOS share-sheet capture

Two small Shortcuts give you one-tap capture from Safari, Instagram, WhatsApp —
anywhere with a share sheet. Both POST to the `ingest` edge function, which
parses with AI and drops the result in the app's Inbox.

- **Endpoint:** `https://gvewzvcvmeztqyfwkgwa.supabase.co/functions/v1/ingest`
- **Secret:** the `INGEST_SECRET` value — print it on the laptop with:

  ```sh
  grep INGEST_SECRET ~/Desktop/for-science-and-pleasure/.supabase.env
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
