// group-membership: the one door for joining, leaving, inviting and renaming.
//
// Authenticated by the caller's JWT; the work runs as the service role
// through security-definer SQL functions (0021_membership.sql) that hold
// every invariant — cap of 2 free / 4 Plus, one group per user, item moves
// with URL dedupe, row locks for the last seat, feed-token rotation. This
// file only checks the caller, shapes the request and maps outcomes to HTTP.
//
//   POST { action: "card" }
//   POST { action: "invite" }                       → { code, expires_at, message }
//   POST { action: "revoke",  code }                → { revoked }
//   POST { action: "preview", code }                → { status, name, members, … }
//   POST { action: "join",    code, keep_copy? }    → { joined, moved, …card }
//   POST { action: "leave",   keep_copy? }          → { left, copied, …card }
//   POST { action: "rename",  name }                → card
//
// Every response is JSON. Business outcomes ("expired", "full", "own"…)
// are 200s with a `status`/`error` field so the app shows a screen, not an
// error; only malformed requests and missing auth are 4xx.
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/extract.ts";
import { admin, displayName } from "../_shared/groups.ts";
import { notifyGroupOfMember } from "../_shared/notify.ts";
import { formatCode, inviteMessage, isAction, NEEDS_CODE, normaliseCode } from "../_shared/membership.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

/** Member pings go out after the reply, so joining never waits on APNs. */
function afterReply(work: Promise<unknown>) {
  const safe = work.catch((e) => console.error("member ping", e));
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(safe);
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

/** The caller's user id from their JWT, group or no group. */
async function callerId(req: Request): Promise<string | null> {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return null;
  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) return null;
  return data.user.id;
}

/** The group the caller is in right now, before a join or leave moves them. */
async function currentGroup(db: ReturnType<typeof admin>, userId: string): Promise<string | null> {
  const { data } = await db.from("group_members").select("group_id").eq("user_id", userId).maybeSingle();
  return data?.group_id ?? null;
}

/** Whether anyone is still in a group someone just left. */
async function hasMembers(db: ReturnType<typeof admin>, groupId: string): Promise<boolean> {
  const { count } = await db
    .from("group_members")
    .select("user_id", { count: "exact", head: true })
    .eq("group_id", groupId);
  return (count ?? 0) > 0;
}

/** The people already in the group hear who arrived; when the joiner left a
 *  shared group to come, the ones left behind hear that too. */
async function announceJoin(db: ReturnType<typeof admin>, userId: string, before: string | null, moved: number) {
  const name = await displayName(db, userId);
  const joined = await currentGroup(db, userId);
  if (joined) {
    await notifyGroupOfMember(db, { groupId: joined, userId, name, change: "joined", broughtSaves: moved > 0 });
  }
  if (before && before !== joined && await hasMembers(db, before)) {
    await notifyGroupOfMember(db, { groupId: before, userId, name, change: "left" });
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const userId = await callerId(req);
  if (!userId) return json({ error: "sign in required" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON body required" }, 400);
  }
  const action = body.action;
  if (!isAction(action)) return json({ error: "unknown action" }, 400);

  let code: string | null = null;
  if (NEEDS_CODE.has(action)) {
    code = normaliseCode(typeof body.code === "string" ? body.code : null);
    // A malformed code is just an unknown one to the person typing it.
    if (!code) return json(action === "revoke" ? { revoked: false } : { status: "unknown" });
  }
  const keepCopy = body.keep_copy === true;

  const db = admin();
  const hourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  if (action === "preview" || action === "join") {
    const { count: userFails } = await db
      .from("invite_attempts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .eq("ok", false)
      .gte("at", hourAgo);
    if ((userFails ?? 0) >= 20) return json({ error: "too_many_attempts" }, 429);
    if (code) {
      const { count: codeFails } = await db
        .from("invite_attempts")
        .select("id", { count: "exact", head: true })
        .eq("code", code)
        .eq("ok", false)
        .gte("at", hourAgo);
      if ((codeFails ?? 0) >= 30) {
        await db.from("group_invites").update({ expires_at: new Date().toISOString() }).eq("code", code);
        return json(action === "preview" ? { status: "unknown" } : { error: "unknown" });
      }
    }
  }
  try {
    switch (action) {
      case "card": {
        const { data, error } = await db.rpc("membership_card", { p_user: userId });
        if (error) throw error;
        return json(data ?? { error: "no_group" });
      }
      case "invite": {
        const { data, error } = await db.rpc("membership_invite", { p_user: userId });
        if (error) throw error;
        if (data?.code) {
          return json({ ...data, code: formatCode(data.code), message: inviteMessage(data.code) });
        }
        return json(data);
      }
      case "revoke": {
        const { data, error } = await db.rpc("membership_revoke", { p_user: userId, p_code: code });
        if (error) throw error;
        return json(data);
      }
      case "preview": {
        const { data, error } = await db.rpc("membership_preview", { p_user: userId, p_code: code });
        if (error) throw error;
        const ok = data?.status === "ok";
        await db.from("invite_attempts").insert({ user_id: userId, code, ok });
        return json(data);
      }
      case "join": {
        const before = await currentGroup(db, userId);
        const { data, error } = await db.rpc("membership_join", {
          p_user: userId,
          p_code: code,
          p_keep_copy: keepCopy,
        });
        if (error) {
          // The cap trigger is the backstop behind the function's own check;
          // if a race slips past, it surfaces as a check_violation here.
          if (error.code === "23514") return json({ error: "full" });
          throw error;
        }
        await db.from("invite_attempts").insert({
          user_id: userId,
          code,
          ok: data?.joined === true,
        });
        if (data?.joined === true) afterReply(announceJoin(db, userId, before, Number(data.moved ?? 0)));
        return json(data);
      }
      case "leave": {
        const before = await currentGroup(db, userId);
        const { data, error } = await db.rpc("membership_leave", { p_user: userId, p_keep_copy: keepCopy });
        if (error) throw error;
        if (data?.left === true && before) {
          afterReply(
            displayName(db, userId).then((name) =>
              notifyGroupOfMember(db, { groupId: before, userId, name, change: "left" })
            ),
          );
        }
        return json(data);
      }
      case "rename": {
        const name = typeof body.name === "string" ? body.name : "";
        const { data, error } = await db.rpc("membership_rename", { p_user: userId, p_name: name });
        if (error) throw error;
        return json(data);
      }
    }
  } catch (e) {
    console.error("group-membership", action, e);
    return json({ error: "Something went wrong. Please try again." }, 500);
  }
});
