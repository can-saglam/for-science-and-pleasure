"""Membership battery for 0021 + the group-membership function. Staging only.

    export SURL=… SANON=… SSVC=…      # staging keys
    python3 supabase/tests/membership_battery.py [--function]

Creates its own throwaway accounts (the new-user trigger must provision
each one), then drives every invariant in the launch plan: provisioning,
auto-names, colours, invite lifecycle (ok/expired/revoked/unknown/own),
2-free/4-Plus cap, join moving saves with URL dedupe, leave with and without
a copy, feed-token rotation, the last-seat race, client lock-out from the
API, and the "Former member" tombstone. With --function the same flows run
through the deployed edge function with real JWTs. Cleans up after itself.
"""
import json, os, sys, uuid, urllib.request, subprocess, threading, datetime

URL, ANON, SVC = os.environ["SURL"], os.environ["SANON"], os.environ["SSVC"]
RUN_FUNCTION = "--function" in sys.argv
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")

failures = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if (detail and not cond) else ""))
    if not cond: failures.append(name)

def req(path, method="GET", body=None, key=None, jwt=None, prefer=None):
    key = key or ANON
    h = {"apikey": key, "Authorization": f"Bearer {jwt or key}", "Content-Type": "application/json", "User-Agent": "curl/8"}
    if prefer: h["Prefer"] = prefer
    r = urllib.request.Request(URL + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            t = resp.read().decode(); return resp.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try: return e.code, json.loads(t)
        except Exception: return e.code, t

def svc(path, method="GET", body=None, prefer=None):
    return req(path, method, body, key=SVC, prefer=prefer)

def sql(q):
    out = subprocess.run(["supabase", "db", "query", "--linked", "--output-format", "json", q],
                         capture_output=True, text=True, cwd=ROOT)
    txt = out.stdout
    try:
        start = txt.index("{"); parsed = json.loads(txt[start:])
        return parsed.get("rows", parsed) if isinstance(parsed, dict) else parsed
    except Exception:
        return {"raw": txt, "err": out.stderr}

def fn(q):
    """Call a jsonb-returning function and return the decoded value."""
    rows = sql(f"select ({q})::text as j")
    if isinstance(rows, list) and rows and "j" in rows[0]:
        v = rows[0]["j"]
        return json.loads(v) if isinstance(v, str) else v
    return {"error": "sql_failed", "detail": rows}

# ---------------------------------------------------------------- accounts
STAMP = uuid.uuid4().hex[:6]
PW = "Battery-" + uuid.uuid4().hex
people = {}
def make_user(tag, name):
    email = f"mb-{tag}-{STAMP}@example.com"
    s, b = svc("/auth/v1/admin/users", "POST", {"email": email, "password": PW, "email_confirm": True})
    assert s == 200, (s, b)
    uid = b["id"]
    s, b = svc(f"/rest/v1/profiles?user_id=eq.{uid}", "PATCH", {"display_name": name}, prefer="return=minimal")
    assert s == 204, (s, b)
    people[tag] = {"email": email, "id": uid, "name": name}
    return uid

def login(tag):
    s, b = req("/auth/v1/token?grant_type=password", "POST", {"email": people[tag]["email"], "password": PW})
    assert s == 200, (s, b)
    return b["access_token"]

def group_of(uid):
    s, b = svc(f"/rest/v1/group_members?user_id=eq.{uid}&select=group_id")
    return b[0]["group_id"] if b else None

def group_row(gid):
    s, b = svc(f"/rest/v1/groups?id=eq.{gid}&select=*")
    return b[0] if b else None

def items_in(gid):
    s, b = svc(f"/rest/v1/items?group_id=eq.{gid}&deleted_at=is.null&select=id,title,url,notes,created_by,remind_at&order=created_at")
    return b

def add_item(gid, uid, title, url=None, notes=None):
    row = {"id": str(uuid.uuid4()), "kind": "place", "status": "saved", "title": title, "url": url, "notes": notes,
           "source": "app", "group_id": gid, "created_by": uid, "updated_by": uid}
    s, b = svc("/rest/v1/items", "POST", [row], prefer="return=minimal")
    assert s == 201, (s, b)
    return row["id"]

PRE_EXISTING_GROUPS = {r["id"] for r in sql("select id from public.groups")}

def cleanup():
    for p in people.values():
        svc(f"/auth/v1/admin/users/{p['id']}", "DELETE")
    # Groups the battery created (their items with them), and the tombstones.
    # groups.created_by is nulled by the user delete, so go by "new since start".
    keep = "(" + ",".join(f"'{g}'" for g in PRE_EXISTING_GROUPS) + ")"
    orphan = f"select g.id from public.groups g where g.id not in {keep} and not exists (select 1 from public.group_members m where m.group_id = g.id)"
    sql(f"delete from public.items where group_id in ({orphan})")
    sql(f"delete from public.groups where id in ({orphan})")
    ids = "(" + ",".join(f"'{p['id']}'" for p in people.values()) + ")"
    sql(f"delete from public.profiles where user_id in {ids}")

try:
    # ------------------------------------------------------------ provisioning
    ann = make_user("ann", "Ann"); bob = make_user("bob", "Bob"); cat = make_user("cat", "Cat")
    dan = make_user("dan", "Dan"); eve = make_user("eve", "Eve"); fay = make_user("fay", "Fay")
    g_ann, g_bob = group_of(ann), group_of(bob)
    check("new user gets a personal group", g_ann is not None and g_bob is not None and g_ann != g_bob)
    s, b = svc(f"/rest/v1/groups?id=eq.{g_ann}&select=home_timezone")
    check("…with a home timezone", s == 200 and b and b[0]["home_timezone"] == "Europe/London", f"{b}")
    check("…named after them", group_row(g_ann)["name"] == "Ann's saves", group_row(g_ann)["name"])
    s, b = svc(f"/rest/v1/profiles?user_id=eq.{ann}&select=avatar_colour")
    check("…with an avatar colour", s == 200 and b and b[0]["avatar_colour"] == "coral", f"{b}")

    founding = sql("select id, name, name_pinned from public.groups order by created_at limit 1")[0]
    check("founding group name pinned", founding["name_pinned"] is True and founding["name"] == "Can & Joyce", str(founding))
    cols = sql(f"select p.avatar_colour from public.group_members m join public.profiles p on p.user_id = m.user_id where m.group_id = '{founding['id']}' order by m.joined_at")
    check("founders got distinct colours", [c["avatar_colour"] for c in cols] == ["coral", "mint"], str(cols))

    # ------------------------------------------------------------ invites
    inv = fn(f"public.membership_invite('{ann}')")
    check("solo free user can invite (1 < 2)", "code" in inv and len(inv["code"]) == 6, str(inv))
    code_ann = inv["code"]
    pv = fn(f"public.membership_preview('{bob}', '{code_ann[:3]}-{code_ann[3:].lower()}')")
    check("preview tolerates dash + case; shows the group", pv.get("status") == "ok" and pv.get("name") == "Ann's saves"
          and pv.get("inviter") == "Ann" and pv.get("capacity") == 2 and len(pv.get("members", [])) == 1, str(pv))
    check("preview never exposes the group's codes or id (0023)",
          "invites" not in pv and "group_id" not in pv and all("user_id" not in m for m in pv.get("members", [])), str(pv))
    check("preview: unknown code", fn(f"public.membership_preview('{bob}', 'ZZZZZZ')").get("status") == "unknown")
    check("preview: own code", fn(f"public.membership_preview('{ann}', '{code_ann}')").get("status") == "own")
    check("client cannot read others' invites", req(f"/rest/v1/group_invites?select=code", jwt=login("bob"))[1] == [])
    check("member reads own group's invites", [r["code"] for r in req(f"/rest/v1/group_invites?select=code", jwt=login("ann"))[1]] == [code_ann])

    # ------------------------------------------------------------ join moves saves, dedupes by URL
    add_item(g_ann, ann, "Ann's cafe", "https://www.example.com/cafe/", notes="Ann's note")
    add_item(g_ann, ann, "Ann only", "https://example.com/only")
    add_item(g_bob, bob, "Bob's cafe", "http://example.com/cafe", notes="Bob's note")
    add_item(g_bob, bob, "Bob only")
    j = fn(f"public.membership_join('{bob}', '{code_ann}', false)")
    check("bob joins ann", j.get("joined") is True and j.get("moved") == 1, str(j))
    check("bob now in ann's group; his old group dissolved", group_of(bob) == g_ann and group_row(g_bob) is None)
    got = items_in(g_ann)
    titles = sorted(i["title"] for i in got)
    check("saves moved in, twin kept (3 items, not 4)", titles == ["Ann only", "Ann's cafe", "Bob only"], str(titles))
    twin = [i for i in got if i["title"] == "Ann's cafe"][0]
    check("twin gained the joiner's notes", twin["notes"] == "Ann's note\n\nBob's note", repr(twin["notes"]))
    check("moved row keeps its author", [i for i in got if i["title"] == "Bob only"][0]["created_by"] == bob)
    check("group renamed itself", group_row(g_ann)["name"] == "Ann & Bob", group_row(g_ann)["name"])
    s, b = svc(f"/rest/v1/profiles?user_id=eq.{bob}&select=avatar_colour")
    check("joiner took the next free colour", b[0]["avatar_colour"] == "mint", str(b))
    check("code stays usable (multi-use)", fn(f"public.membership_preview('{cat}', '{code_ann}')").get("status") == "plus_required")

    # ------------------------------------------------------------ cap: 2 free / 4 plus
    j = fn(f"public.membership_join('{cat}', '{code_ann}', false)")
    check("third free member is refused with plus_required", j.get("error") == "plus_required", str(j))
    check("free pair cannot invite", fn(f"public.membership_invite('{ann}')").get("error") == "plus_required")
    svc("/rest/v1/entitlements", "POST", {"user_id": cat, "tier": "plus", "source": "promo"}, prefer="return=minimal")
    check("preview shows ok once the joiner is Plus", fn(f"public.membership_preview('{cat}', '{code_ann}')").get("status") == "ok")
    j = fn(f"public.membership_join('{cat}', '{code_ann}', false)")
    check("plus joiner gets in as third", j.get("joined") is True and j.get("is_plus") is True and j.get("capacity") == 4, str(j))
    check("name: 'Ann, Bob & Cat'", group_row(g_ann)["name"] == "Ann, Bob & Cat", group_row(g_ann)["name"])
    j = fn(f"public.membership_join('{dan}', '{code_ann}', false)")
    check("fourth joins (group is plus via cat)", j.get("joined") is True, str(j))
    j = fn(f"public.membership_join('{eve}', '{code_ann}', false)")
    check("fifth refused: full", j.get("error") == "full", str(j))
    check("full group cannot invite", fn(f"public.membership_invite('{ann}')").get("error") == "full")
    s, b = svc(f"/rest/v1/group_members?group_id=eq.{g_ann}&select=user_id")
    check("exactly 4 members", len(b) == 4)

    # ------------------------------------------------------------ leave
    ann_only = next(i for i in items_in(g_ann) if i["title"] == "Ann only")
    svc(f"/rest/v1/items?id=eq.{ann_only['id']}", "PATCH", {
        "starts_on": "2026-12-22", "ends_on": "2026-12-22",
        "reminder_offset_days": 7, "reminder_anchor": "starts_on", "remind_at": "2026-12-15",
    }, prefer="return=minimal")
    tok_before = group_row(g_ann)["feed_token"]
    l = fn(f"public.membership_leave('{dan}', true)")
    check("dan leaves with a copy", l.get("left") is True and l.get("copied") == 3 and l.get("former_group_name") == "Ann, Bob, Cat & Dan", str(l))
    g_dan = group_of(dan)
    check("dan has a fresh personal group named for him", g_dan not in (g_ann, None) and group_row(g_dan)["name"] == "Dan's saves", str(group_row(g_dan)))
    check("copy is a copy: group still has 3, dan has 3", len(items_in(g_ann)) == 3 and len(items_in(g_dan)) == 3)
    check("copies keep original authors", sorted({i["created_by"] for i in items_in(g_dan)}) == sorted({ann, bob}))
    dan_ann = [i for i in items_in(g_dan) if i["title"] == "Ann only"]
    check("copy keeps reminder", dan_ann and dan_ann[0].get("remind_at") == "2026-12-15", str(dan_ann))
    check("feed token rotated on leave", group_row(g_ann)["feed_token"] != tok_before)
    check("group renamed after leave", group_row(g_ann)["name"] == "Ann, Bob & Cat", group_row(g_ann)["name"])
    s, b = svc(f"/rest/v1/groups?id=eq.{g_dan}&select=home_timezone")
    check("new group inherits home timezone", s == 200 and b and b[0]["home_timezone"] == "Europe/London")
    l = fn(f"public.membership_leave('{cat}', false)")
    check("cat leaves without a copy", l.get("left") is True and l.get("copied") == 0 and len(items_in(group_of(cat))) == 0, str(l))
    check("group dropped to free: 2 members, capacity 2", fn(f"public.membership_card('{ann}')").get("capacity") == 2)
    check("leaving a solo group is a no-op", fn(f"public.membership_leave('{dan}', false)").get("error") == "already_solo")

    # ------------------------------------------------------------ shared → another group, atomically
    inv_dan = fn(f"public.membership_invite('{dan}')")["code"]
    j = fn(f"public.membership_join('{bob}', '{inv_dan}', true)")
    # Dan already holds copies of the two URL-bearing items; only the URL-less one is new.
    check("bob leaves ann for dan with a copy", j.get("joined") is True and j.get("moved") == 1, str(j))
    check("ann's group untouched (3 items), bob in dan's", len(items_in(g_ann)) == 3 and group_of(bob) == g_dan)
    check("dan's group deduped by URL: 4 not 6", len(items_in(g_dan)) == 4, str(len(items_in(g_dan))))
    check("ann is solo again: 'Ann's saves'", group_row(g_ann)["name"] == "Ann's saves", group_row(g_ann)["name"])

    # ------------------------------------------------------------ rename pins, empty unpins
    r = fn(f"public.membership_rename('{dan}', '  The Dream Team  ')")
    check("rename pins", r.get("name") == "The Dream Team" and r.get("name_pinned") is True, str(r))
    fn(f"public.membership_leave('{bob}', false)")
    check("pinned name survives membership change", group_row(g_dan)["name"] == "The Dream Team")
    r = fn(f"public.membership_rename('{dan}', '')")
    check("empty rename unpins → auto name", r.get("name") == "Dan's saves", str(r))
    r = fn(f"public.membership_rename('{dan}', '{'x' * 40}')")
    check("rename capped at 30", len(r.get("name", "")) == 30)

    # ------------------------------------------------------------ expiry, revoke
    inv_ann2 = fn(f"public.membership_invite('{ann}')")["code"]
    sql(f"update public.group_invites set expires_at = now() - interval '1 minute' where code = '{inv_ann2}'")
    check("expired code", fn(f"public.membership_preview('{eve}', '{inv_ann2}')").get("status") == "expired")
    check("join refused on expired", fn(f"public.membership_join('{eve}', '{inv_ann2}', false)").get("error") == "expired")
    inv_ann3 = fn(f"public.membership_invite('{ann}')")["code"]
    check("revoke by outsider does nothing", fn(f"public.membership_revoke('{eve}', '{inv_ann3}')").get("revoked") is False)
    check("revoke by member", fn(f"public.membership_revoke('{ann}', '{inv_ann3}')").get("revoked") is True)
    pv_dead = fn(f"public.membership_preview('{eve}', '{inv_ann3}')")
    check("revoked code", pv_dead.get("status") == "revoked")
    check("a dead code learns only the inviter's name (0023)", set(pv_dead) <= {"status", "inviter"}, str(pv_dead))
    check("helpers not callable by clients (0023)",
          req("/rest/v1/rpc/user_is_plus", "POST", {"uid": ann}, jwt=login("bob"))[0] in (401, 403, 404))
    live = [i["code"] for i in fn(f"public.membership_card('{ann}')").get("invites", [])]
    check("card lists only live invites (the first, still-valid code)", live == [code_ann], str(live))

    # ------------------------------------------------------------ last-seat race
    inv_ann4 = fn(f"public.membership_invite('{ann}')")["code"]   # ann solo → capacity 2, one seat
    results = []
    def race(uid): results.append(fn(f"public.membership_join('{uid}', '{inv_ann4}', false)"))
    ts = [threading.Thread(target=race, args=(u,)) for u in (eve, fay)]
    [t.start() for t in ts]; [t.join() for t in ts]
    outcomes = sorted("joined" if r.get("joined") else r.get("error", "?") for r in results)
    check("last seat: one joins, one sees plus_required", outcomes == ["joined", "plus_required"], str(outcomes))
    s, b = svc(f"/rest/v1/group_members?group_id=eq.{g_ann}&select=user_id")
    check("…and the group has exactly 2", len(b) == 2)
    win, lose = ("eve", "fay") if group_of(eve) == g_ann else ("fay", "eve")
    win_id, lose_id = people[win]["id"], people[lose]["id"]

    # ------------------------------------------------------------ clients are locked out of the API
    jwt_win, jwt_lose = login(win), login(lose)
    s, b = req("/rest/v1/rpc/membership_invite", "POST", {"p_user": win_id}, jwt=jwt_win)
    check("authenticated cannot call membership_invite", s in (401, 403, 404), f"{s} {b}")
    s, b = req("/rest/v1/rpc/membership_join", "POST", {"p_user": lose_id, "p_code": inv_ann4, "p_keep_copy": False}, jwt=jwt_lose)
    check("authenticated cannot call membership_join", s in (401, 403, 404), f"{s} {b}")
    s, b = req("/rest/v1/group_members", "POST", {"user_id": lose_id, "group_id": g_ann}, jwt=jwt_lose)
    check("client cannot insert group_members", s in (401, 403), f"{s} {b}")
    s, b = req("/rest/v1/group_invites", "POST", {"code": "ABCDEF", "group_id": g_ann}, jwt=jwt_win)
    check("client cannot insert invites", s in (401, 403), f"{s} {b}")
    s, b = req(f"/rest/v1/groups?id=eq.{g_ann}", "PATCH", {"feed_token": "hijack"}, jwt=jwt_lose)
    check("stranger cannot touch the group row", s in (401, 403, 204) and group_row(g_ann)["feed_token"] != "hijack", f"{s} {b}")
    s, b = req(f"/rest/v1/profiles?user_id=eq.{win_id}", "PATCH", {"display_name": "x" * 25}, jwt=jwt_win)
    check("display name over 24 rejected", s == 400, f"{s} {b}")
    s, b = req(f"/rest/v1/profiles?user_id=eq.{win_id}", "PATCH", {"display_name": "Winner"}, jwt=jwt_win, prefer="return=minimal")
    check("own rename allowed and group renames", s == 204 and group_row(g_ann)["name"] == "Ann & Winner", f"{s} {group_row(g_ann)['name']}")

    # ------------------------------------------------------------ tombstone
    win_item = add_item(g_ann, win_id, "Winner's pick")
    s, b = svc(f"/auth/v1/admin/users/{win_id}", "DELETE")
    check("delete the winner's auth user", s == 200, f"{s} {b}")
    s, b = svc(f"/rest/v1/profiles?user_id=eq.{win_id}&select=user_id,display_name")
    check("profile survives as a tombstone", s == 200 and len(b) == 1, f"{b}")
    s, b = svc(f"/rest/v1/items?id=eq.{win_item}&select=created_by")
    check("item keeps its author id", b and b[0]["created_by"] == win_id, str(b))
    s, b = req(f"/rest/v1/profiles?user_id=eq.{win_id}&select=display_name", jwt=login("ann"))
    check("remaining member can still read the former member's profile", s == 200 and len(b) == 1, f"{s} {b}")
    check("membership row gone with the user", group_of(win_id) is None)
    check("group renamed without them", group_row(g_ann)["name"] == "Ann's saves", group_row(g_ann)["name"])

    # ------------------------------------------------------------ edge function
    if RUN_FUNCTION:
        def gm(jwt, body):
            return req("/functions/v1/group-membership", "POST", body, jwt=jwt)
        s, b = req("/functions/v1/group-membership", "POST", {"action": "card"})
        check("fn: anon → 401", s == 401, f"{s} {b}")
        jwt_ann, jwt_bob = login("ann"), login("bob")   # ann solo, bob solo, both free
        s, b = gm(jwt_ann, {"action": "nope"}); check("fn: unknown action → 400", s == 400)
        s, b = gm(jwt_ann, {"action": "card"}); check("fn: card", s == 200 and b.get("name") == "Ann's saves", f"{s} {b}")
        s, b = gm(jwt_ann, {"action": "invite"})
        check("fn: invite formats code and message", s == 200 and "-" in b.get("code", "") and b.get("message", "").startswith("Join Ann on Can We Go? — code "), f"{s} {b}")
        code = b["code"]
        s, b = gm(jwt_lose, {"action": "preview", "code": code.lower()}); check("fn: preview", s == 200 and b.get("status") == "ok", f"{s} {b}")
        s, b = gm(jwt_lose, {"action": "preview", "code": "not a code"}); check("fn: malformed code → unknown", s == 200 and b.get("status") == "unknown", f"{s} {b}")
        s, b = gm(jwt_lose, {"action": "join", "code": code}); check("fn: join", s == 200 and b.get("joined") is True, f"{s} {b}")
        s, b = gm(jwt_bob, {"action": "join", "code": code}); check("fn: third free → plus_required as a 200", s == 200 and b.get("error") == "plus_required", f"{s} {b}")
        s, b = gm(jwt_ann, {"action": "rename", "name": "Us"}); check("fn: rename", s == 200 and b.get("name") == "Us", f"{s} {b}")
        s, b = gm(jwt_lose, {"action": "leave", "keep_copy": True}); check("fn: leave with copy", s == 200 and b.get("left") is True and b.get("former_group_name") == "Us", f"{s} {b}")
        s, b = gm(jwt_ann, {"action": "revoke", "code": code}); check("fn: revoke", s == 200 and b.get("revoked") is True, f"{s} {b}")
finally:
    cleanup()

print()
print("ALL GREEN" if not failures else f"{len(failures)} FAILED: {failures}")
sys.exit(1 if failures else 0)
