import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export const CAPS = { parse: 40, locate: 40, suggest: 8 } as const;
export type QuotaKind = keyof typeof CAPS;

/** Increment today's counter. Returns false when the cap is already hit. */
export async function consumeQuota(
  db: SupabaseClient,
  userId: string,
  kind: QuotaKind,
): Promise<boolean> {
  const day = new Date().toISOString().slice(0, 10);
  const { data: existing } = await db
    .from("usage_daily")
    .select("parse, locate, suggest")
    .eq("user_id", userId)
    .eq("day", day)
    .maybeSingle();
  const used = (existing?.[kind] as number | undefined) ?? 0;
  if (used >= CAPS[kind]) return false;

  if (!existing) {
    const row = { user_id: userId, day, parse: 0, locate: 0, suggest: 0, [kind]: 1 };
    const { error } = await db.from("usage_daily").insert(row);
    return !error;
  }
  const { error } = await db
    .from("usage_daily")
    .update({ [kind]: used + 1 })
    .eq("user_id", userId)
    .eq("day", day);
  return !error;
}

export const quotaResponse = () =>
  new Response(JSON.stringify({ error: "daily limit reached" }), {
    status: 429,
    headers: { "Content-Type": "application/json" },
  });
