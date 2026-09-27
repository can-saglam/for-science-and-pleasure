// delete-account: the caller removes their login. A shared library is left
// for whoever remains (they leave; feed_token rotates; their invite codes
// go). A solo library is torn down with them, photos included. Their email
// comes off every save they made, and their usage and invite-attempt rows
// go. An Apple sign-in sends a fresh authorization code, and the app's
// Sign in with Apple access is revoked once the account is gone. JWT
// required; work runs as the service role.
import { corsHeaders } from "../_shared/extract.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { admin } from "../_shared/groups.ts";
import { revokeAppleAccess, type RevokeOutcome } from "../_shared/siwa.ts";

/// A solo library's cover photos live under its group's folder.
async function removeGroupPhotos(db: SupabaseClient, groupId: string): Promise<void> {
  const bucket = db.storage.from("item-images");
  for (let round = 0; round < 50; round++) {
    const { data, error } = await bucket.list(groupId, { limit: 1000 });
    if (error || !data?.length) return;
    const paths = data.filter((f) => f.name).map((f) => `${groupId}/${f.name}`);
    if (paths.length === 0) return;
    const { error: removeError } = await bucket.remove(paths);
    if (removeError) throw removeError;
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  const db = admin();
  const { data: userData, error: userErr } = await db.auth.getUser(auth.slice(7));
  const uid = userData?.user?.id;
  const email = userData?.user?.email?.trim() ?? "";
  if (userErr || !uid) return json({ error: "unauthorized" }, 401);

  const body = await req.json().catch(() => ({})) as { apple_code?: unknown };
  const appleCode = typeof body.apple_code === "string" && body.apple_code.length < 2048 ? body.apple_code : null;
  const appleIdentity = userData.user.identities?.find((i) => i.provider === "apple");
  const appleSub = (appleIdentity?.identity_data?.sub as string | undefined) ?? appleIdentity?.id ?? null;

  try {
    const { data: mem } = await db
      .from("group_members")
      .select("group_id")
      .eq("user_id", uid)
      .maybeSingle();

    if (mem?.group_id) {
      const { count } = await db
        .from("group_members")
        .select("user_id", { count: "exact", head: true })
        .eq("group_id", mem.group_id);
      const others = (count ?? 1) - 1;

      if (others > 0) {
        await db.from("group_members").delete().eq("user_id", uid);
        // Codes they handed out stop letting people into a library they've left.
        await db.from("group_invites").delete().eq("group_id", mem.group_id).eq("created_by", uid);
        await db
          .from("groups")
          .update({ feed_token: crypto.randomUUID().replaceAll("-", "") })
          .eq("id", mem.group_id);
      } else {
        await removeGroupPhotos(db, mem.group_id);
        await db.from("live_activity_runs").delete().eq("group_id", mem.group_id);
        await db.from("notify_recent").delete().eq("group_id", mem.group_id);
        await db.from("items").delete().eq("group_id", mem.group_id);
        await db.from("group_invites").delete().eq("group_id", mem.group_id);
        await db.from("group_members").delete().eq("group_id", mem.group_id);
        await db.from("groups").delete().eq("id", mem.group_id);
      }
    }

    // Saves they made in any library keep the save, not their address.
    if (email) {
      const { error: forgetError } = await db.rpc("forget_saver", { p_email: email });
      if (forgetError) throw forgetError;
    }
    await db.from("usage_daily").delete().eq("user_id", uid);
    await db.from("invite_attempts").delete().eq("user_id", uid);
    await db.from("notify_recent").delete().eq("actor", uid);
    await db.from("apns_tokens").delete().eq("user_id", uid);
    await db.from("profiles").delete().eq("user_id", uid);
    const { error: delErr } = await db.auth.admin.deleteUser(uid);
    if (delErr) throw delErr;

    // The account is gone either way; a revocation that fails is logged.
    let apple: RevokeOutcome | undefined;
    if (appleCode) {
      apple = await revokeAppleAccess(appleCode, appleSub).catch((e) => {
        console.error("siwa", e);
        return "failed" as const;
      });
      if (apple !== "revoked") console.error("siwa outcome", apple);
    }
    return json({ deleted: true, apple });
  } catch (e) {
    console.error(e);
    return json({ error: "could not delete account" }, 500);
  }
});
