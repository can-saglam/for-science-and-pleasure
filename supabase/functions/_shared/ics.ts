// Calendar-file text (RFC 5545): escaped values, the timestamp every event
// needs, and lines folded at 75 octets.

/** A TEXT value: backslashes, commas and semicolons escaped, any line break as \n. */
export function icsText(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/\r\n|\r|\n/g, "\\n").replace(/[,;]/g, (c) => `\\${c}`);
}

/** A web link for URL:, or null when it isn't one (or carries a line break). */
export function icsLink(raw: string | null | undefined): string | null {
  if (!raw || /[\r\n]/.test(raw)) return null;
  try {
    const u = new URL(raw);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch {
    return null;
  }
}

/** DTSTAMP's form: 20261120T151500Z. */
export function icsStamp(at: Date): string {
  return at.toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
}

/** Lines over 75 octets continue on lines that start with a space. */
export function icsFold(line: string): string {
  const bytes = (s: string) => new TextEncoder().encode(s).length;
  const out: string[] = [];
  let rest = line;
  while (bytes(rest) > 75) {
    let cut = 74;
    while (bytes(rest.slice(0, cut)) > 74) cut--;
    out.push(rest.slice(0, cut));
    rest = ` ${rest.slice(cut)}`;
  }
  out.push(rest);
  return out.join("\r\n");
}
