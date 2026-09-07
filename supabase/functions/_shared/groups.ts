// Group resolution for edge functions (Phase 1b). The unit of access is
// the caller's group: RLS scopes every table by it, and these helpers give
// functions the same answer RLS would.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export interface Caller {
  /** RLS-scoped client carrying the caller's JWT. */
  client: SupabaseClient;
  userId: string;
  email: string | null;
  groupId: string;
}

/**
 * Resolve the caller from the Authorization header. Returns null when the
 * JWT is missing/invalid or the user isn't in a group yet (a signed-in user
 * with no group can't read or write anything group-scoped, so functions
 * treat that the same as unauthenticated).
 */
export async function resolveCaller(req: Request): Promise<Caller | null> {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return null;
  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const [{ data: groupId, error }, { data: userData }] = await Promise.all([
    client.rpc("current_group_id"),
    client.auth.getUser(),
  ]);
  if (error || !groupId || !userData?.user) return null;
  return {
    client,
    userId: userData.user.id,
    email: userData.user.email ?? null,
    groupId: groupId as string,
  };
}

export function admin(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}

/**
 * Which group a calendar/digest URL key belongs to. Each group has its own
 * feed_token. The pre-groups FEED_SECRET / INGEST_SECRET keys keep working
 * for the founding group so the calendar subscriptions added before 1b
 * don't silently stop updating.
 */
export async function groupForFeedKey(
  db: SupabaseClient,
  key: string | null,
): Promise<string | null> {
  if (!key) return null;
  const { data: byToken } = await db
    .from("groups")
    .select("id")
    .eq("feed_token", key)
    .maybeSingle();
  if (byToken?.id) return byToken.id;

  const legacy = Deno.env.get("FEED_SECRET") ?? Deno.env.get("INGEST_SECRET");
  if (legacy && key === legacy) {
    const { data: founding } = await db
      .from("groups")
      .select("id")
      .order("created_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    return founding?.id ?? null;
  }
  return null;
}

/** The group a legacy Shortcut save belongs to, from its added_by email. */
export async function groupForEmail(
  db: SupabaseClient,
  email: string | null | undefined,
): Promise<{ groupId: string; userId: string } | null> {
  if (!email) return null;
  const { data, error } = await db.rpc("group_for_email", { p_email: email });
  if (error || !data) return null;
  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.group_id) return null;
  return { groupId: row.group_id, userId: row.user_id };
}

/** Display name for a user, from profiles; falls back to the email's local part. */
export async function displayName(
  db: SupabaseClient,
  userId: string | null | undefined,
  email?: string | null,
): Promise<string> {
  if (userId) {
    const { data } = await db
      .from("profiles")
      .select("display_name")
      .eq("user_id", userId)
      .maybeSingle();
    if (data?.display_name) return data.display_name;
  }
  return email?.split("@")[0] ?? "Someone";
}

/** APNs tokens of everyone in the group, optionally excluding one user. */
export async function groupTokens(
  db: SupabaseClient,
  groupId: string,
  excludeUserId?: string | null,
): Promise<string[]> {
  const { data: members } = await db
    .from("group_members")
    .select("user_id")
    .eq("group_id", groupId);
  const ids = (members ?? [])
    .map((m: { user_id: string }) => m.user_id)
    .filter((id: string) => id !== excludeUserId);
  if (ids.length === 0) return [];
  const { data: tokens } = await db
    .from("apns_tokens")
    .select("token")
    .in("user_id", ids);
  return (tokens ?? []).map((t: { token: string }) => t.token);
}

export const jsonHeaders = { "Content-Type": "application/json" };
