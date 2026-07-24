/** Keep in sync with supabase/functions/_shared/limits.ts */
export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

export function imageTooLargeMessage(): string {
  return `Screenshot too large (max ${MAX_IMAGE_BYTES / (1024 * 1024)}MB)`;
}
