"""Production-safe RLS probe: a brand-new account sees only its own personal group and touches nothing of anyone else's.
Creates a throwaway user, probes every table + function gate, deletes it.
Targets whatever .supabase.env points at (override with SUPABASE_URL/_ANON_KEY/_SERVICE_ROLE_KEY)."""
import json, os, sys, uuid, urllib.request, secrets, datetime

ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".supabase.env")
env = dict(l.rstrip("\n").split("=", 1) for l in open(ENV_FILE) if "=" in l and not l.startswith("#"))
env = {**env, **{k: v for k, v in os.environ.items() if k in ("SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY")}}
URL, ANON, SVC = env["SUPABASE_URL"].rstrip("/"), env["SUPABASE_ANON_KEY"], env["SUPABASE_SERVICE_ROLE_KEY"]
fails = []
def check(n, c, d=""):
    print(("PASS " if c else "FAIL ") + n + (f"  [{d}]" if d and not c else ""))
    if not c: fails.append(n)
def http(path, method="GET", body=None, jwt=None, key=None, prefer=None):
    h = {"apikey": key or ANON, "Authorization": f"Bearer {jwt or key or ANON}", "Content-Type": "application/json", "User-Agent": "curl/8"}
    if prefer: h["Prefer"] = prefer
    r = urllib.request.Request(URL + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            t = resp.read().decode(); return resp.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try: return e.code, json.loads(t)
        except Exception: return e.code, t

email = f"rls-probe-{secrets.token_hex(4)}@example.com"; pw = secrets.token_urlsafe(20)
s, u = http("/auth/v1/admin/users", "POST", {"email": email, "password": pw, "email_confirm": True}, key=SVC)
assert s == 200, (s, u); uid = u["id"]; print("probe user", uid[:8])
own_gid = None
try:
    s, tok = http("/auth/v1/token?grant_type=password", "POST", {"email": email, "password": pw}); jwt = tok["access_token"]

    # Since 0021 every new account is provisioned into a personal group, so a
    # stranger sees exactly their own rows and nothing of anyone else's.
    s, b = http("/rest/v1/rpc/current_group_id", "POST", {}, jwt=jwt); own_gid = b
    check("stranger was provisioned into a personal group", s == 200 and isinstance(own_gid, str), f"{s} {b}")
    s, g = http("/rest/v1/groups?select=id&order=created_at&limit=1", key=SVC); gid = g[0]["id"]
    check("…which is not the founding group", own_gid != gid)
    s, b = http("/rest/v1/items?select=id", jwt=jwt); check("stranger reads 0 items", s == 200 and b == [], f"{s} {b}")
    s, b = http("/rest/v1/groups?select=id", jwt=jwt); check("stranger reads only own group", s == 200 and [r["id"] for r in b] == [own_gid], f"{s} {b}")
    s, b = http("/rest/v1/group_members?select=user_id", jwt=jwt); check("stranger reads only own membership", s == 200 and [r["user_id"] for r in b] == [uid], f"{s} {b}")
    s, b = http("/rest/v1/profiles?select=user_id", jwt=jwt); check("stranger reads only own profile", s == 200 and [r["user_id"] for r in b] == [uid], f"{s} {b}")
    s, b = http("/rest/v1/digest_schedules?select=group_id", jwt=jwt); check("stranger reads only own schedule", s == 200 and [r["group_id"] for r in b] == [own_gid], f"{s} {b}")
    for t in ["entitlements", "apns_tokens", "group_invites"]:
        s, b = http(f"/rest/v1/{t}?select=*", jwt=jwt); check(f"stranger reads 0 rows from {t}", s == 200 and b == [], f"{s} {b}")
    for t in ["items", "groups", "group_members", "profiles", "entitlements", "digest_schedules", "apns_tokens", "app_config", "digest_runs", "group_invites"]:
        s, b = http(f"/rest/v1/{t}?select=*", jwt=None); check(f"anon gets nothing from {t}", s in (401, 403) or b == [], f"{s} {b}")
    s, b = http("/rest/v1/rpc/group_for_email", "POST", {"p_email": email}, jwt=jwt); check("group_for_email() not callable by users", s in (401, 403, 404), f"{s} {b}")
    for rpc, body in (("membership_invite", {"p_user": uid}), ("membership_join", {"p_user": uid, "p_code": "ABCDEF", "p_keep_copy": False}), ("membership_card", {"p_user": uid})):
        s, b = http(f"/rest/v1/rpc/{rpc}", "POST", body, jwt=jwt); check(f"{rpc}() not callable by users", s in (401, 403, 404), f"{s} {b}")

    s, before = http("/rest/v1/items?select=id", key=SVC); n_before = len(before)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    row = {"id": str(uuid.uuid4()), "kind": "event", "status": "saved", "title": "probe", "source": "app", "created_at": now, "updated_at": now}
    s, b = http("/rest/v1/items", "POST", [row], jwt=jwt, prefer="return=minimal"); check("stranger can save into own group", s == 201, f"{s} {b}")
    s, b = http(f"/rest/v1/items?id=eq.{row['id']}&select=group_id", key=SVC); check("…and it landed in their own group", b and b[0]["group_id"] == own_gid, f"{b}")
    s, b = http("/rest/v1/items?deleted_at=is.null&select=id", "PATCH", {"title": "pwned"}, jwt=jwt, prefer="return=representation"); check("stranger blanket UPDATE touches only own row", [r["id"] for r in b] == [row["id"]] or s in (400, 401, 403), f"{s} {b}")
    s, b = http("/rest/v1/items?deleted_at=is.null&select=id", "DELETE", jwt=jwt, prefer="return=representation"); check("stranger blanket DELETE touches only own row", [r["id"] for r in b] == [row["id"]] or s in (400, 401, 403), f"{s} {b}")
    s, after = http("/rest/v1/items?select=id", key=SVC); check("everyone else's items untouched", len(after) == n_before, f"{n_before} → {len(after)}")
    s, b = http("/rest/v1/group_members", "POST", {"group_id": gid, "user_id": uid}, jwt=jwt, prefer="return=minimal"); check("stranger cannot add self to your group", s in (401, 403), f"{s} {b}")
    s, b = http(f"/rest/v1/group_members?user_id=eq.{uid}", "PATCH", {"group_id": gid}, jwt=jwt, prefer="return=representation"); check("stranger cannot move own membership into your group", b == [] or s in (401, 403, 404), f"{s} {b}")
    s, b = http("/rest/v1/entitlements", "POST", {"user_id": uid, "tier": "plus"}, jwt=jwt, prefer="return=minimal"); check("stranger cannot grant self an entitlement", s in (400, 401, 403), f"{s} {b}")
    s, b = http("/rest/v1/groups", "POST", {"name": "hijack"}, jwt=jwt, prefer="return=minimal"); check("stranger cannot create a group directly", s in (401, 403), f"{s} {b}")
    s, b = http("/rest/v1/group_invites", "POST", {"code": "ABCDEF", "group_id": own_gid}, jwt=jwt, prefer="return=minimal"); check("stranger cannot mint an invite directly", s in (401, 403), f"{s} {b}")
    s, b = http("/rest/v1/app_config?id=eq.true&select=min_build", "PATCH", {"min_build": 999}, jwt=jwt, prefer="return=representation"); check("stranger cannot touch app_config", b == [] or s in (401, 403), f"{s} {b}")
    s, b = http("/rest/v1/app_config?select=min_build", jwt=jwt); check("signed-in user can read app_config (kill switch)", s == 200 and len(b) == 1, f"{s} {b}")

    # Functions serve any signed-in member of a group — the stranger is one
    # now, of their own — but must never reach anyone else's rows.
    s, b = http("/functions/v1/notify-save", "POST", {"item_id": str(uuid.uuid4())}, jwt=jwt); check("notify-save: nothing to send for a stranger", s in (200, 403, 404) and (b or {}).get("sent", 0) == 0, f"{s} {b}")
    s, b = http("/functions/v1/suggest", "POST", {"date": "2026-09-12"}, jwt=jwt); check("suggest: stranger sees no plans from your library", s in (200, 403) and (b or {}).get("plans", []) == [], f"{s} {b}")
    s, b = http("/functions/v1/group-membership", "POST", {"action": "card"}, jwt=jwt); check("group-membership: card is own solo group", s == 200 and b.get("group_id") == own_gid and len(b.get("members", [])) == 1, f"{s} {b}")
    s, b = http("/functions/v1/group-membership", "POST", {"action": "card"}); check("group-membership: anon → 401", s == 401, f"{s} {b}")
    s, b = http(f"/functions/v1/ingest", "POST", {"text": "x", "added_by": email}, key=ANON, jwt=None)
    check("ingest: no secret → 401", s == 401, f"{s} {b}")
finally:
    s, b = http(f"/auth/v1/admin/users/{uid}", "DELETE", key=SVC); print("probe user deleted:", s)
    # The probe's own personal group (and anything in it) and its profile tombstone go too.
    if own_gid:
        http(f"/rest/v1/items?group_id=eq.{own_gid}", "DELETE", key=SVC)
        http(f"/rest/v1/groups?id=eq.{own_gid}", "DELETE", key=SVC)
    s, b = http(f"/rest/v1/profiles?user_id=eq.{uid}", "DELETE", key=SVC)
    s, b = http(f"/rest/v1/items?title=in.(probe,pwned)&select=id", key=SVC); check("no probe rows left behind", b == [], f"{b}")
    s, b = http(f"/rest/v1/groups?id=eq.{own_gid}&select=id", key=SVC); check("probe group removed", b == [], f"{b}")

print(); print(f"{len(fails)} failure(s)" if fails else "ALL PASS — production stranger probe")
sys.exit(1 if fails else 0)
