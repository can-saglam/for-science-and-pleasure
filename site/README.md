# wegocan.com

The marketing site: one page, plus support, privacy, terms, the invite
page (`/join/KV7P2M`) and the shared-save page (`/s/Ab3dEf7hJk`). Plain
HTML, CSS and a little JavaScript; the only build step is
`node site/build.mjs`, which fills in partials and config and writes
`site/dist/`.

```sh
node site/build.mjs
cd site/dist && python3 -m http.server 4321   # http://localhost:4321
```

Locally, try the invite page as `/join/?code=KV7P2M` and a shared save as
`/s/?t=<token>` (the `/join/KV7P2M` and `/s/<token>` forms are Cloudflare
rewrites, see `src/_redirects`).

On a phone with the app, both open in the app instead: that's
`src/.well-known/apple-app-site-association`, which Apple fetches from
`https://wegocan.com` (no redirects allowed, so not from `www`).

## What lives where

- `src/s/index.html`, `js/save.js`, `css/save.css`: a save someone sent.
  The card comes from the `share` function (`shareApi` in the config).
  `functions/s/[token].js` runs on Cloudflare in front of that page and
  writes the save's title and photo into it, so chat previews show the
  event (the app icon, `img/share-icon.png`, when there's no usable photo).
  Try it locally with `cd site && npx wrangler pages dev dist`.
- `site.config.json`: domain, contact email, tagline, App Store ID. Set
  `appStoreId` once the app has one: every download button and the Smart App
  Banner pick it up. Until then the buttons point at the footer.
- `src/index.html`: the page. A fan of seven phones, then the icon, a line,
  three short paragraphs and the download button. The phones are plain HTML
  (`.device` in `css/site.css`); each one's place in the fan is its `--i`,
  from -3 to 3, and the two marked `far` are hidden on narrow screens.
- `src/img/shots/`: the screenshots in the phones, from the simulator
  (`xcrun simctl io booted screenshot`), resized to 600 px wide (the middle
  one 720). Each is a launch with `CWG_NO_PROMPTS=1`, a status bar of 9:41
  and full battery, and these variables:
  - `map.jpg`: `CWG_THEME=moss CWG_TAB=1 CWG_MAP=1`
  - `places.jpg`: `CWG_THEME=stone CWG_TAB=1` (give it ~14 s for the photos)
  - `salman-toor.jpg`: `CWG_THEME=forest CWG_OPEN=toor CWG_DETENT=large`
  - `library.jpg`: `CWG_THEME=midnight` (~14 s, after the logo animation);
    the middle phone's poster, shown before the reel plays
  - `anish-kapoor.jpg`: `CWG_THEME=wine CWG_OPEN=kapoor CWG_DETENT=large`
  - `sensual-mutual.jpg`: `CWG_THEME=blush CWG_OPEN=sensual`
  - `composer.jpg`: `CWG_THEME=petrol CWG_CAPTURE=1`, with the simulator's
    hardware keyboard disconnected so the on-screen one shows

  `CWG_OPEN` matches a save in your own library by title, so swap in
  whatever's current when these end.
- `src/partials/logo.svg` and `src/js/logo.js`: the logo above the
  headline, written in like the app's launch animation once it scrolls into
  view. The SVG is generated from the app's
  `ios/CanWeGo/Views/CanWeGoLogoData.swift` by `python3 site/logo.py`; run
  it again if the logo changes.
- The home page's colours come from `data-bg` on its `<body>`: `midnight`,
  `petrol`, `terracotta`, `oat` or `blush`, each with that app theme's
  ink. Remove it for the original cream.
- `src/media/reel.mp4`: the middle phone's loop, 600 px wide, about 22 s.
  A UI test drove the app in midnight with `CWG_NO_PROMPTS=1 CWG_NO_SAVE=1`
  while `simctl io recordVideo` filmed it: scroll the library, tap +, tap
  the Robert Ryman suggestion, Save, open Anish Kapoor, pull it to full
  height, close. The waits are cut out with short dissolves. `CWG_NO_SAVE`
  makes Save say "Saved" without writing or announcing anything. It pauses
  for anyone with reduced motion on.
- Privacy and terms are rendered from `ios/CanWeGo/Resources/PRIVACY.md` and
  `TERMS.md`, the same files the app shows. Support is `src/support.md`.

## Deploying (Cloudflare Pages)

`wegocan.com` is registered at GoDaddy with its DNS on Cloudflare. The
site goes up from this folder:

```sh
node site/build.mjs
cd site && npx wrangler pages deploy dist --project-name wegocan --branch main
```

Run it from `site/`: that's where wrangler finds `functions/`, which goes up
with the pages. Cloudflare keeps scripts and stylesheets for hours, so the
build adds each one's content hash to its address (`save.js?v=…`); a changed
file reaches visitors straight away.

Once, to set it up:

1. Workers & Pages → Create → Pages → Direct upload, project `wegocan`
   (or run the deploy above, which offers to create it).
2. The project → Custom domains → add `wegocan.com`, then `www.wegocan.com`.
   Rules → Redirect Rules → `www.wegocan.com/*` to `https://wegocan.com/${1}`
   (301), so there's one address.
3. Web Analytics: turn it on for the Pages project. It's cookieless and
   injected by Cloudflare, so there's nothing in the code.
4. Email → Email Routing → route `hello@wegocan.com` to your inbox.

Check after each deploy that
`curl -sI https://wegocan.com/.well-known/apple-app-site-association`
answers 200 with `content-type: application/json`.

The old GitHub Pages site (`docs/`) stays up until after launch. When App
Store Connect points at `wegocan.com/privacy/`, `/terms/` and `/support/`,
it can go.
