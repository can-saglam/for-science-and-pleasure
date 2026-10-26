// wegocan.com/s/<token>/calendar: the save as a calendar file, which Safari
// offers straight to Calendar. Like the app's Add to calendar: an all-day
// event across its run, shown as free so it doesn't block the day; a
// one-day save with a set time gets that time instead.

import { shared } from "../../../lib/share.js";

const compact = (iso) => iso.replaceAll("-", "");
const escape = (s) => s.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/[,;]/g, (c) => `\\${c}`);

function nextDay(iso) {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

// Lines over 75 octets fold onto continuation lines starting with a space.
function fold(line) {
  const out = [];
  let rest = line;
  while (new TextEncoder().encode(rest).length > 75) {
    let cut = 74;
    while (new TextEncoder().encode(rest.slice(0, cut)).length > 74) cut--;
    out.push(rest.slice(0, cut));
    rest = ` ${rest.slice(cut)}`;
  }
  out.push(rest);
  return out.join("\r\n");
}

export async function onRequestGet({ params }) {
  const save = await shared(params.token);
  const card = save?.card;
  const first = card?.starts_on ?? card?.ends_on;
  if (!first) return new Response("Not found", { status: 404 });
  const last = card.ends_on ?? first;

  const timed = first === last
    ? card.showings?.find((s) => s.date === first && s.time)?.time
    : null;
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
  const when = timed
    ? (() => {
      const [h, m] = timed.split(":").map(Number);
      const end = `${String(Math.min(h + 2, 23)).padStart(2, "0")}${String(m).padStart(2, "0")}00`;
      return [`DTSTART:${compact(first)}T${timed.replace(":", "")}00`, `DTEND:${compact(first)}T${end}`];
    })()
    : [`DTSTART;VALUE=DATE:${compact(first)}`, `DTEND;VALUE=DATE:${compact(nextDay(last))}`, "TRANSP:TRANSPARENT"];
  const place = [card.venue, card.address ?? card.area].filter(Boolean).join(", ");
  const about = [card.summary, card.url].filter(Boolean).join("\n\n");

  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Can We Go?//Shared save//EN",
    "CALSCALE:GREGORIAN",
    "BEGIN:VEVENT",
    `UID:shared-${save.token}@wegocan.com`,
    `DTSTAMP:${stamp}`,
    ...when,
    `SUMMARY:${escape(card.title)}`,
    ...(place ? [`LOCATION:${escape(place)}`] : []),
    ...(about ? [`DESCRIPTION:${escape(about)}`] : []),
    ...(card.url ? [`URL:${card.url}`] : []),
    ...(card.lat != null && card.lng != null ? [`GEO:${card.lat};${card.lng}`] : []),
    "END:VEVENT",
    "END:VCALENDAR",
  ];
  // Headers are Latin-1, so the file's name keeps plain letters only.
  const filename = card.title.normalize("NFD").replace(/[^A-Za-z0-9 ]+/g, "").trim().slice(0, 60) || "event";
  return new Response(lines.map(fold).join("\r\n") + "\r\n", {
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": `inline; filename="${filename}.ics"`,
      "Cache-Control": "public, max-age=60",
    },
  });
}
