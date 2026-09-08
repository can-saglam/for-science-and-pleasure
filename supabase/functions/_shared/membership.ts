// Pure helpers for the group-membership function: invite-code shape and the
// action vocabulary. The invariants themselves (cap, one group per user,
// item moves, locks) live in SQL — see migrations/0021_membership.sql.

/** Codes use an alphabet without 0/O/1/I so they survive being read aloud. */
export const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_RE = /^[A-HJ-NP-Z2-9]{6}$/;

/**
 * "kv7-p2m", " KV7 P2M ", "KV7P2M" → "KV7P2M". Null when it can't be a
 * code, so callers show "unknown" without a round-trip.
 */
export function normaliseCode(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const c = raw.toUpperCase().replace(/[\s-]/g, "");
  return CODE_RE.test(c) ? c : null;
}

/** "KV7P2M" → "KV7-P2M", the way it's shown and shared. */
export function formatCode(code: string): string {
  const c = code.toUpperCase();
  return c.length === 6 ? `${c.slice(0, 3)}-${c.slice(3)}` : c;
}

export const ACTIONS = ["card", "invite", "revoke", "preview", "join", "leave", "rename"] as const;
export type Action = (typeof ACTIONS)[number];

export function isAction(x: unknown): x is Action {
  return typeof x === "string" && (ACTIONS as readonly string[]).includes(x);
}

/** Which actions need a code, and which take a keep_copy flag. */
export const NEEDS_CODE: ReadonlySet<Action> = new Set(["revoke", "preview", "join"]);
export const TAKES_KEEP_COPY: ReadonlySet<Action> = new Set(["join", "leave"]);

/** The share-sheet message. The App Store link slots in at launch. */
export function inviteMessage(code: string, inviter: string | null, storeURL: string | null): string {
  const who = inviter ? `Join ${inviter} on Can We Go?` : "Join me on Can We Go?";
  const link = storeURL ? ` ${storeURL}` : "";
  return `${who} — code ${formatCode(code)}${link}`;
}
