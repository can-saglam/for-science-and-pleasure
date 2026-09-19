// delete-account: the caller removes their login. A shared library is left
// for whoever remains (they leave; feed_token rotates). A solo library is
// torn down with them. JWT required; work runs as the service role.
import { corsHeaders } from "../_shared/extract.ts";
import { admin } from "../_shared/groups.ts";

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
  if (userErr || !uid) return json({ error: "unauthorized" }, 401);

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
        await db
          .from("groups")
          .update({ feed_token: crypto.randomUUID().replaceAll("-", "") })
          .eq("id", mem.group_id);
      } else {
        await db.from("items").delete().eq("group_id", mem.group_id);
        await db.from("group_invites").delete().eq("group_id", mem.group_id);
        await db.from("group_members").delete().eq("group_id", mem.group_id);
        await db.from("groups").delete().eq("id", mem.group_id);
      }
    }

    await db.from("apns_tokens").delete().eq("user_id", uid);
    await db.from("profiles").delete().eq("user_id", uid);
    const { error: delErr } = await db.auth.admin.deleteUser(uid);
    if (delErr) throw delErr;
    return json({ deleted: true });
  } catch (e) {
    console.error(e);
    return json({ error: "could not delete account" }, 500);
  }
});
