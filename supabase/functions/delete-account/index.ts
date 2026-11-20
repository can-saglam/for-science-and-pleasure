// delete-account: the caller removes their login. A shared library is left
// for whoever remains (they leave; feed_token rotates; their invite codes
// go). A solo library is torn down with them, photos included. Their rows
// go in one transaction (delete_account_data, 0053) before the login does,
// so a failure leaves the account whole and the person can try again. An Apple sign-in sends a fresh authorization code, and the app's
// Sign in with Apple access is revoked once the account is gone. JWT
// required; work runs as the service role.
import { corsHeaders } from "../_shared/extract.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { admin, displayName } from "../_shared/groups.ts";
import { notifyGroupOfMember } from "../_shared/notify.ts";
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
    // Read before the profile goes, so the ping still has their name.
    const name = mem?.group_id ? await displayName(db, uid, email) : "";

    // Every row of theirs, in one transaction: all of it or none of it.
    const { data: gone, error: dataErr } = await db.rpc("delete_account_data", { p_user: uid });
    if (dataErr) throw dataErr;
    const { group_id: groupId, others } = gone as { group_id: string | null; others: number };

    if (groupId && others > 0) {
      await notifyGroupOfMember(db, { groupId, userId: uid, name, change: "left" })
        .catch((e) => console.error("left ping", e));
    } else if (groupId) {
      // Photos aren't rows: a failure leaves files nobody can reach, not data.
      await removeGroupPhotos(db, groupId).catch((e) => console.error("photos", e));
    }

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
