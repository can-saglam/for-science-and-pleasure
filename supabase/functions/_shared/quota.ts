import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

/** AI calls per person per day, parse + locate + suggest together. Plus
 * comes from the group: anyone covered by a member's subscription gets it.
 * Never mentioned in the app: the limit people see is ten (or fifty) new
 * saves a day (0043). This is the ceiling behind it, for lookups that are
 * never saved, and twice that so nobody adding normally meets it. */
export const DAILY = { free: 20, plus: 100 } as const;
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

/** Whether today's allowance has room for one more call. Counts nothing. */
export async function hasQuota(db: SupabaseClient, userId: string): Promise<boolean> {
  const day = new Date().toISOString().slice(0, 10);
  const { data: existing } = await db
    .from("usage_daily")
    .select("parse, locate, suggest")
    .eq("user_id", userId)
    .eq("day", day)
    .maybeSingle();
  const used = (existing?.parse ?? 0) + (existing?.locate ?? 0) + (existing?.suggest ?? 0);
  return used < DAILY.free || (used < DAILY.plus && await coveredByPlus(db, userId));
}

/** Count one call against today's allowance. */
export async function chargeQuota(db: SupabaseClient, userId: string, kind: QuotaKind): Promise<boolean> {
  const day = new Date().toISOString().slice(0, 10);
  const { error } = await db.rpc("bump_usage", { p_user_id: userId, p_day: day, p_kind: kind });
  return !error;
}

/** Increment today's counter. Returns false when the day's allowance is spent. */
export async function consumeQuota(
  db: SupabaseClient,
  userId: string,
  kind: QuotaKind,
): Promise<boolean> {
  return await hasQuota(db, userId) && await chargeQuota(db, userId, kind);
}

/** Opening-hours lookups per person per day: each is a billed Google call,
 * counted apart from the AI allowance. Far more than opening every save. */
export const DAILY_HOURS = 200;

export async function consumeHours(db: SupabaseClient, userId: string): Promise<boolean> {
  const day = new Date().toISOString().slice(0, 10);
  const { data, error } = await db.rpc("bump_hours", { p_user_id: userId, p_day: day });
  return !error && typeof data === "number" && data <= DAILY_HOURS;
}

/** Searches that weren't saves, before the note gets firmer and a quick
 * check answers text in place of a full lookup. */
export const VAGUE_STRIKES = 4;

export async function vagueStrikes(db: SupabaseClient, userId: string): Promise<number> {
  const day = new Date().toISOString().slice(0, 10);
  const { data } = await db.from("usage_daily").select("vague").eq("user_id", userId).eq("day", day).maybeSingle();
  return data?.vague ?? 0;
}

/** Today's count after this one. */
export async function bumpVague(db: SupabaseClient, userId: string): Promise<number> {
  const day = new Date().toISOString().slice(0, 10);
  const { data, error } = await db.rpc("bump_vague", { p_user_id: userId, p_day: day });
  return !error && typeof data === "number" ? data : 0;
}

export const quotaResponse = () =>
  new Response(JSON.stringify({ error: "daily limit reached" }), {
    status: 429,
    headers: { "Content-Type": "application/json" },
  });
