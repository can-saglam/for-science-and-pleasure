const encoder = new TextEncoder();

/**
 * Whether a supplied secret matches, in time that doesn't depend on how
 * much of it matched. Missing on either side never matches.
 */
export function sameSecret(given: string | null | undefined, expected: string | null | undefined): boolean {
  if (!given || !expected) return false;
  const a = encoder.encode(given);
  const b = encoder.encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= a[i % a.length] ^ b[i];
  return diff === 0;
}

/** Safe client-facing 500 body — log the real error server-side instead. */
export function internalErrorBody(): string {
  return JSON.stringify({ error: "internal error" });
}
