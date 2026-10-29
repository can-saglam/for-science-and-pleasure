// Can We Go? — a shared save. The server usually writes the save into the
// page (functions/s/[token].js); otherwise it's fetched from the share
// function, by the token in /s/<token> (or ?t= when testing locally).
//
// Anyone with the app who taps the link lands in the app, not here, so this
// page is mostly read by people without it: the main button gets the app,
// and the card is useful on its own (dates, price, directions, calendar).

import { when, where } from "./when.js";

const page = document.body;
const fromPath = location.pathname.split("/").filter(Boolean)[1] ?? "";
const token = (new URLSearchParams(location.search).get("t") ?? fromPath).replace(/[^A-Za-z0-9]/g, "");
const $ = (name) => document.querySelector(`[data-${name}]`);
const iPhone = /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

function fill(name, text) {
  const el = $(name);
  if (!text) return el;
  el.textContent = text;
  el.hidden = false;
  return el;
}

function link(name, href) {
  const el = $(name);
  el.href = href;
  el.hidden = false;
}

// Apple Maps on an iPhone, Google Maps everywhere else.
function directions(card) {
  const name = [card.venue, card.address].filter(Boolean).join(", ");
  const hasSpot = card.lat != null && card.lng != null;
  if (!name && !hasSpot) return null;
  if (iPhone) {
    const q = new URLSearchParams({ q: card.venue || card.title });
    if (hasSpot) q.set("ll", `${card.lat},${card.lng}`);
    else q.set("address", name);
    return `https://maps.apple.com/?${q}`;
  }
  const q = new URLSearchParams({ api: "1", query: name || `${card.lat},${card.lng}` });
  if (card.place_id) q.set("query_place_id", card.place_id);
  return `https://www.google.com/maps/search/?${q}`;
}

function show({ card, from }) {
  $("loading").hidden = true;
  fill("from", from ? `${from} sent you this` : "Someone sent you this from Can We Go?");
  if (card.color) page.style.setProperty("--save-accent", card.color.startsWith("#") ? card.color : `#${card.color}`);

  if (card.image_url && !card.image_url.includes("/functions/v1/place-photo")) {
    const photo = $("photo");
    const frame = $("photo-link");
    photo.src = card.image_url;
    photo.onerror = () => (frame.hidden = true);
    if (card.url) frame.href = card.url;
    frame.hidden = false;
  }
  $("title").textContent = card.title;
  document.title = `${card.title} · Can We Go?`;
  fill("where", where(card));
  const on = when(card);
  if (on) {
    const line = fill("when", on.text);
    line.classList.toggle("is-urgent", !!on.urgent);
    line.classList.toggle("is-over", !!on.over);
  }
  fill("price", card.price);
  fill("summary", card.summary);
  fill("address", card.address);

  if (card.url) link("page", card.url);
  // Where it leads, so a card can't pass off a stranger's page as the event's.
  const host = card.url ? new URL(card.url).hostname.replace(/^www\./, "") : "";
  $("page").textContent = `${card.kind === "place" ? "Website" : "Event page"}${host ? ` · ${host}` : ""}`;
  const maps = directions(card);
  if (maps) link("directions", maps);
  if (on && !on.over && token.length === 10) link("calendar", `/s/${token}/calendar`);

  $("iphone").href = `canwego://s/${token}`;
  $(iPhone ? "iphone" : "elsewhere").hidden = false;
  page.classList.toggle("is-iphone", iPhone);
  $("card").hidden = false;
  $("actions").hidden = false;
}

function missing() {
  $("loading").hidden = true;
  $("missing").hidden = false;
}

// A 404 is final; anything else (a cold start, a dropped connection) gets
// one more try before the page gives up.
async function load(tries = 2) {
  try {
    const res = await fetch(`${page.dataset.api}?t=${token}`);
    if (res.status === 404) return missing();
    if (!res.ok) throw new Error(res.status);
    const body = await res.json();
    body.card?.title ? show(body) : missing();
  } catch {
    if (tries > 1) setTimeout(() => load(tries - 1), 1500);
    else missing();
  }
}

let preloaded = null;
try {
  preloaded = JSON.parse(page.dataset.preload ?? "null");
} catch {}

if (preloaded?.card?.title) show(preloaded);
else if (token.length !== 10) missing();
else load();
