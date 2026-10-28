// Can We Go? — the invite page. Reads the code from /join/KV7P2M (or
// ?code=KV7P2M when testing locally) and points "Open the invite" at the
// app. Who's asking comes written into the page (functions/join/[code].js)
// or, failing that, from the share function. Codes are six letters or
// digits, as the app expects (DigestGate.swift).
//
// Anyone with the app who taps the link lands in the app, not here, so the
// page is mostly read by people without it. Download copies the code first:
// the app's first run offers to paste it, so the invite survives the trip
// through the App Store.

const page = document.body;
const $ = (name) => document.querySelector(`[data-${name}]`);
const fromPath = location.pathname.split("/").filter(Boolean)[1] ?? "";
const raw = new URLSearchParams(location.search).get("code") ?? fromPath;
const code = decodeURIComponent(raw).toUpperCase().replace(/[^A-Z0-9]/g, "");
const shown = `${code.slice(0, 3)}-${code.slice(3)}`;

// The app's palette (AvatarColour in GroupStore.swift): swatch, then ink.
const COLOURS = {
  coral: ["#fa7366", "#fff"],
  mint: ["#6bd9ad", "#000c"],
  sky: ["#66b3fa", "#000c"],
  lilac: ["#b89ef5", "#000c"],
  amber: ["#fab84d", "#000c"],
  rose: ["#f58cb8", "#000c"],
  teal: ["#4dbfbf", "#fff"],
  plum: ["#b36bbf", "#fff"],
};

function names(list) {
  if (list.length < 2) return list[0] ?? "";
  return `${list.slice(0, -1).join(", ")} and ${list.at(-1)}`;
}

function faces(members) {
  const row = $("faces");
  for (const m of members) {
    const [bg, ink] = COLOURS[m.colour] ?? ["rgba(246, 226, 182, .25)", "var(--cream)"];
    const face = document.createElement("span");
    face.className = "join-face";
    face.style.background = bg;
    face.style.color = ink;
    face.textContent = [...m.name][0].toUpperCase();
    face.setAttribute("aria-hidden", "true");
    row.append(face);
  }
  row.hidden = members.length === 0;
}

// Only a live invite gets the steps; a dead one just says who to ask.
function closed(title, lede) {
  $("title").textContent = title;
  $("lede").textContent = lede;
  for (const name of ["steps", "open", "code-box", "fine"]) $(name).hidden = true;
}

function show({ status, from, members = [] }) {
  const who = names(members.map((m) => m.name)) || from;
  if (status === "expired") {
    closed("This invite has expired", `Invites last a week. Ask ${from ?? "whoever sent it"} for a new one.`);
    return;
  }
  if (status === "full") {
    faces(members);
    closed("This list is full", `${who || "Four people"} already share it, and four is the most a list holds.`);
    return;
  }
  faces(members);
  if (from) $("title").textContent = `${from} invited you`;
  if (who) {
    $("lede").textContent =
      `Share a Can We Go? list with ${who}: the exhibitions, gigs and restaurants you’ll go to together.`;
  }
}

async function lookUp() {
  try {
    const preloaded = JSON.parse(page.dataset.preload ?? "null");
    if (preloaded?.status) return preloaded;
    const res = await fetch(`${page.dataset.api}?i=${code}`);
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

async function copyCode() {
  try {
    await navigator.clipboard.writeText(shown);
    return true;
  } catch {
    return false;
  }
}

if (code.length === 6) {
  $("code").textContent = shown;
  $("open").href = `canwego://join/${code}`;

  const copy = $("copy");
  copy.addEventListener("click", async () => {
    copy.textContent = (await copyCode()) ? "Copied" : "Select and copy";
    setTimeout(() => (copy.textContent = "Copy"), 2000);
  });

  const download = $("download");
  download.addEventListener("click", async (event) => {
    event.preventDefault();
    await copyCode();
    location.href = download.href;
  });

  $("join").hidden = false;
  lookUp().then((invite) => invite?.status && show(invite));
} else {
  $("join-missing").hidden = false;
}
