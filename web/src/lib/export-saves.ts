import type { Item } from "./types";

function downloadFile(name: string, content: string, type: string) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}

function exportDate() {
  return new Date().toISOString().slice(0, 10);
}

function itemDates(item: Item): string | null {
  if (item.starts_on && item.ends_on) return `${item.starts_on} to ${item.ends_on}`;
  if (item.starts_on) return `from ${item.starts_on}`;
  if (item.ends_on) return `until ${item.ends_on}`;
  return null;
}

export function exportSavesAsMarkdown(items: Item[]) {
  const sections = [
    { title: "Saved", items: items.filter((item) => item.status === "saved") },
    { title: "Done", items: items.filter((item) => item.status === "done") },
    // Legacy status — only emitted if any old rows remain.
    {
      title: "Archived",
      items: items.filter((item) => item.status === "archived"),
    },
  ].filter((section) => section.items.length > 0);

  const body = sections
    .map(
      (section) =>
        `# ${section.title}\n\n` +
        section.items
          .map((item) => {
            const details = [
              `- Type: ${item.kind}`,
              item.category && `- Category: ${item.category}`,
              item.venue && `- Venue: ${item.venue}`,
              item.area && `- Area: ${item.area}`,
              item.address && `- Address: ${item.address}`,
              itemDates(item) && `- Dates: ${itemDates(item)}`,
              item.price && `- Price: ${item.price}`,
              item.url && `- Source: <${item.url}>`,
              item.booking_url && `- Booking: <${item.booking_url}>`,
              item.added_by_email && `- Added by: ${item.added_by_email}`,
            ].filter(Boolean);

            return [
              `## ${item.title}`,
              details.join("\n"),
              item.summary,
              item.notes && `### Notes\n\n${item.notes}`,
            ]
              .filter(Boolean)
              .join("\n\n");
          })
          .join("\n\n---\n\n"),
    )
    .join("\n\n");

  const markdown = [
    "# Can We Go? — Saves",
    `Exported ${exportDate()}`,
    body || "_No saved items yet._",
  ].join("\n\n");
  downloadFile(`can-we-go-saves-${exportDate()}.md`, markdown, "text/markdown");
}

function escapeXml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function evernoteDate(value: string): string {
  return new Date(value)
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
}

function noteContent(item: Item): string {
  const rows = [
    ["Type", item.kind],
    ["Status", item.status],
    ["Category", item.category],
    ["Venue", item.venue],
    ["Area", item.area],
    ["Address", item.address],
    ["Dates", itemDates(item)],
    ["Price", item.price],
    ["Added by", item.added_by_email],
  ]
    .filter((entry): entry is [string, string] => Boolean(entry[1]))
    .map(
      ([label, value]) =>
        `<div><b>${escapeXml(label)}:</b> ${escapeXml(value)}</div>`,
    );

  const links = [
    item.url &&
      `<div><a href="${escapeXml(item.url)}">Source link</a></div>`,
    item.booking_url &&
      `<div><a href="${escapeXml(item.booking_url)}">Booking link</a></div>`,
  ].filter(Boolean);

  return [
    item.summary && `<div>${escapeXml(item.summary)}</div><br/>`,
    ...rows,
    links.length > 0 && "<br/>",
    ...links,
    item.notes &&
      `<br/><div><b>Notes</b></div><div>${escapeXml(item.notes).replaceAll("\n", "<br/>")}</div>`,
  ]
    .filter(Boolean)
    .join("");
}

export function exportSavesForAppleNotes(items: Item[]) {
  const notes = items
    .map((item) => {
      const created = evernoteDate(item.created_at);
      const updated = evernoteDate(item.updated_at);
      const tags = [item.kind, item.category, item.status]
        .filter(Boolean)
        .map((tag) => `<tag>${escapeXml(tag!)}</tag>`)
        .join("");
      const content =
        '<?xml version="1.0" encoding="UTF-8"?>' +
        '<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">' +
        `<en-note>${noteContent(item)}</en-note>`;

      return [
        "<note>",
        `<title>${escapeXml(item.title)}</title>`,
        `<content><![CDATA[${content}]]></content>`,
        `<created>${created}</created>`,
        `<updated>${updated}</updated>`,
        tags,
        "</note>",
      ].join("");
    })
    .join("");

  const now = evernoteDate(new Date().toISOString());
  const enex = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export3.dtd">',
    `<en-export export-date="${now}" application="Can We Go?" version="1.0">`,
    notes,
    "</en-export>",
  ].join("\n");

  downloadFile(
    `can-we-go-saves-${exportDate()}.enex`,
    enex,
    "application/xml",
  );
}
