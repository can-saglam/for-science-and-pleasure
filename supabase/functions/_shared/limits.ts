/** Max decoded screenshot size accepted by parse/ingest (4 MiB). */
export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

/** Approximate decoded byte length of a base64 payload. */
export function base64DecodedBytes(base64: string): number {
  const trimmed = base64.trim();
  const padding = trimmed.endsWith("==") ? 2 : trimmed.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((trimmed.length * 3) / 4) - padding);
}

export function assertImageWithinLimit(image_base64: unknown): void {
  if (typeof image_base64 !== "string" || !image_base64) return;
  if (base64DecodedBytes(image_base64) > MAX_IMAGE_BYTES) {
    throw new Error(`image too large (max ${MAX_IMAGE_BYTES / (1024 * 1024)}MB)`);
  }
}
