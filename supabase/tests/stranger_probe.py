"""Production-safe RLS probe: a brand-new account must see and touch nothing.
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
try:
    s, tok = http("/auth/v1/token?grant_type=password", "POST", {"email": email, "password": pw}); jwt = tok["access_token"]

    for t in ["items", "groups", "group_members", "profiles", "entitlements", "digest_schedules", "apns_tokens"]:
        s, b = http(f"/rest/v1/{t}?select=*", jwt=jwt); check(f"stranger reads 0 rows from {t}", s == 200 and b == [], f"{s} {b}")
    for t in ["items", "groups", "group_members", "profiles", "entitlements", "digest_schedules", "apns_tokens", "app_config", "digest_runs"]:
        s, b = http(f"/rest/v1/{t}?select=*", jwt=None); check(f"anon gets nothing from {t}", s in (401, 403) or b == [], f"{s} {b}")
    s, b = http("/rest/v1/rpc/current_group_id", "POST", {}, jwt=jwt); check("current_group_id() is null", s == 200 and b is None, f"{s} {b}")
    s, b = http("/rest/v1/rpc/group_for_email", "POST", {"p_email": email}, jwt=jwt); check("group_for_email() not callable by users", s in (401, 403, 404), f"{s} {b}")

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    row = {"id": str(uuid.uuid4()), "kind": "event", "status": "saved", "title": "probe", "source": "app", "created_at": now, "updated_at": now}
    s, b = http("/rest/v1/items", "POST", [row], jwt=jwt, prefer="return=minimal"); check("stranger cannot insert an item", s in (400, 401, 403), f"{s} {b}")
    s, b = http("/rest/v1/items?deleted_at=is.null&select=id", "PATCH", {"title": "pwned"}, jwt=jwt, prefer="return=representation"); check("stranger blanket UPDATE touches 0 rows", b == [] or s in (400, 401, 403), f"{s} {b}")
    s, b = http("/rest/v1/items?deleted_at=is.null", "DELETE", jwt=jwt, prefer="return=representation"); check("stranger blanket DELETE touches 0 rows", b == [] or s in (400, 401, 403), f"{s} {b}")
    s, g = http("/rest/v1/groups?select=id", key=SVC); gid = g[0]["id"]
    s, b = http("/rest/v1/group_members", "POST", {"group_id": gid, "user_id": uid}, jwt=jwt, prefer="return=minimal"); check("stranger cannot add self to your group", s in (401, 403), f"{s} {b}")
    s, b = http("/rest/v1/entitlements", "POST", {"user_id": uid, "tier": "plus"}, jwt=jwt, prefer="return=minimal"); check("stranger cannot grant self an entitlement", s in (400, 401, 403), f"{s} {b}")
    s, b = http("/rest/v1/groups", "POST", {"name": "hijack"}, jwt=jwt, prefer="return=minimal"); check("stranger cannot create a group directly (Phase 2 does it server-side)", s in (401, 403), f"{s} {b}")
    s, b = http("/rest/v1/app_config?id=eq.true&select=min_build", "PATCH", {"min_build": 999}, jwt=jwt, prefer="return=representation"); check("stranger cannot touch app_config", b == [] or s in (401, 403), f"{s} {b}")
    s, b = http("/rest/v1/app_config?select=min_build", jwt=jwt); check("signed-in user can read app_config (kill switch works pre-group)", s == 200 and len(b) == 1, f"{s} {b}")

    for fn, body in (("notify-save", {"item_id": str(uuid.uuid4())}), ("suggest", {"date": "2026-09-12"}), ("parse", {"text": "hi"}), ("locate", {"items": [{"id": "x"}]})):
        s, b = http(f"/functions/v1/{fn}", "POST", body, jwt=jwt); check(f"{fn}: stranger → 403", s == 403, f"{s} {b}")
    s, b = http(f"/functions/v1/ingest", "POST", {"text": "x", "added_by": email}, key=ANON, jwt=None)
    check("ingest: no secret → 401", s == 401, f"{s} {b}")
finally:
    s, b = http(f"/rest/v1/profiles?user_id=eq.{uid}", "DELETE", key=SVC)
    s, b = http(f"/auth/v1/admin/users/{uid}", "DELETE", key=SVC); print("probe user deleted:", s)
    s, b = http(f"/rest/v1/items?title=eq.probe&select=id", key=SVC); check("no probe rows left behind", b == [], f"{b}")

print(); print(f"{len(fails)} failure(s)" if fails else "ALL PASS — production stranger probe")
sys.exit(1 if fails else 0)
