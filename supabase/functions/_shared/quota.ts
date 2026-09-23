import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

/** AI calls per person per day, parse + locate + suggest together. Plus
 * comes from the group: anyone covered by a member's subscription gets it. */
export const DAILY = { free: 10, plus: 50 } as const;
export type QuotaKind = "parse" | "locate" | "suggest";

async function coveredByPlus(db: SupabaseClient, userId: string): Promise<boolean> {
  const { data: mine } = await db.from("group_members").select("group_id").eq("user_id", userId).maybeSingle();
  const ids = [userId];
  if (mine?.group_id) {
    const { data: members } = await db.from("group_members").select("user_id").eq("group_id", mine.group_id);
    for (const m of members ?? []) if (m.user_id !== userId) ids.push(m.user_id);
  }
  const { count } = await db
    .from("entitlements")
    .select("user_id", { count: "exact", head: true })
    .in("user_id", ids)
    .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`);
  return (count ?? 0) > 0;
}

/** Increment today's counter. Returns false when the day's allowance is spent. */
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
  const used = (existing?.parse ?? 0) + (existing?.locate ?? 0) + (existing?.suggest ?? 0);
  if (used >= DAILY.free && (used >= DAILY.plus || !(await coveredByPlus(db, userId)))) return false;

  if (!existing) {
    const row = { user_id: userId, day, parse: 0, locate: 0, suggest: 0, [kind]: 1 };
    const { error } = await db.from("usage_daily").insert(row);
    return !error;
  }
  const { error } = await db
    .from("usage_daily")
    .update({ [kind]: ((existing[kind] as number | undefined) ?? 0) + 1 })
    .eq("user_id", userId)
    .eq("day", day);
  return !error;
}

export const quotaResponse = () =>
  new Response(JSON.stringify({ error: "daily limit reached" }), {
    status: 429,
    headers: { "Content-Type": "application/json" },
  });
