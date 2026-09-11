"""RLS/behaviour battery. Run as: python3 rls_battery.py 1a|1b   (see README.md)

Signs in as Can, Joyce and a stranger with real password-grant JWTs and
drives PostgREST the way the iOS app does. Every check prints PASS/FAIL;
exit code is non-zero if anything failed.
"""
import json, os, sys, uuid, urllib.request, datetime, subprocess

PHASE = sys.argv[1]
URL, ANON, SVC = os.environ["SURL"], os.environ["SANON"], os.environ["SSVC"]
creds = json.load(open(os.environ.get("CREDS_FILE", "/tmp/stg_creds.json")))
STRANGER = "stranger@example.com"
members = [e for e in creds if e != STRANGER]
CAN, JOYCE = members[0], members[1]  # any two members of the same group

failures = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if (detail and not cond) else ""))
    if not cond: failures.append(name)

def http(path, method="GET", body=None, jwt=None, prefer=None):
    h = {"apikey": ANON, "Authorization": f"Bearer {jwt or ANON}", "Content-Type": "application/json", "User-Agent": "curl/8"}
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
    h = {"apikey": SVC, "Authorization": f"Bearer {SVC}", "Content-Type": "application/json", "User-Agent": "curl/8"}
    if prefer: h["Prefer"] = prefer
    r = urllib.request.Request(URL + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            t = resp.read().decode(); return resp.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def sql(q):
    out = subprocess.run(["supabase", "db", "query", "--linked", "--output-format", "json", q],
                         capture_output=True, text=True, cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")).stdout
    try:
        start = out.index("{"); return json.loads(out[start:]).get("rows", [])
    except Exception:
        return out

def login(email):
    s, b = http("/auth/v1/token?grant_type=password", "POST", {"email": email, "password": creds[email]})
    assert s == 200, (email, s, b)
    return b["access_token"], b["user"]["id"]

s, rows = svc("/rest/v1/items?select=id")
TOTAL = len(rows)  # includes soft-deleted rows: RLS is about rows, not status
can_jwt, can_id = login(CAN)
joyce_jwt, joyce_id = login(JOYCE)
str_jwt, str_id = login(STRANGER)
print(f"phase={PHASE}  can={can_id[:8]} joyce={joyce_id[:8]} stranger={str_id[:8]}")

# ---------------------------------------------------------------- reads
s, rows = http("/rest/v1/items?select=id", jwt=can_jwt);  check(f"can reads all {TOTAL} items", s == 200 and len(rows) == TOTAL, f"{s} {len(rows) if isinstance(rows, list) else rows}")
s, rows = http("/rest/v1/items?select=id", jwt=joyce_jwt); check(f"joyce reads all {TOTAL} items", s == 200 and len(rows) == TOTAL, f"{s}")
s, rows = http("/rest/v1/items?select=id", jwt=str_jwt); check("stranger reads 0 items", s == 200 and rows == [], f"{s} {rows}")
s, rows = http("/rest/v1/items?select=id", jwt=None); check("anon reads 0 items", s in (200, 401) and (rows == [] or s == 401), f"{s} {rows}")

# ---------------------------------------------------------------- insert as the app does (build 40 shape: group_id null in payload)
new_id = str(uuid.uuid4())
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
row = {"id": new_id, "kind": "event", "status": "saved", "title": "RLS test item", "summary": None, "venue": None,
       "area": None, "address": None, "category": None, "price": None, "url": None, "booking_url": None,
       "starts_on": None, "ends_on": None, "lat": None, "lng": None, "image_url": None, "color": None,
       "source": "app", "raw_input": None, "added_by_email": CAN, "created_at": now, "updated_at": now,
       "deleted_at": None, "group_id": None, "updated_by": None}
s, b = http("/rest/v1/items", "POST", [row], jwt=can_jwt, prefer="resolution=merge-duplicates,return=minimal")
check("can inserts a row with group_id=null (build 40 payload)", s == 201, f"{s} {b}")
s, b = svc(f"/rest/v1/items?id=eq.{new_id}&select=group_id,updated_by")
check("trigger filled group_id + updated_by", s == 200 and b and b[0]["group_id"] and b[0]["updated_by"] == can_id, f"{s} {b}")
gid = b[0]["group_id"] if b else None
if PHASE == "1b":
    s, b = svc(f"/rest/v1/items?id=eq.{new_id}&select=created_by")
    check("1b: created_by stamped from JWT", s == 200 and b[0]["created_by"] == can_id, f"{b}")

# build-38 shape: no group_id/updated_by keys at all
old_id = str(uuid.uuid4())
row38 = {k: v for k, v in row.items() if k not in ("group_id", "updated_by")}; row38["id"] = old_id; row38["title"] = "RLS test (old client)"
s, b = http("/rest/v1/items", "POST", [row38], jwt=joyce_jwt, prefer="resolution=merge-duplicates,return=minimal")
check("joyce inserts with no group keys (build 38 payload)", s == 201, f"{s} {b}")

# ---------------------------------------------------------------- partner edit
later = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=1)).isoformat()
s, b = http(f"/rest/v1/items?id=eq.{new_id}", "PATCH", {"title": "RLS test item (edited by joyce)", "updated_at": later}, jwt=joyce_jwt, prefer="return=representation")
check("joyce edits can's item", s == 200 and b and b[0]["title"].endswith("joyce)"), f"{s} {b}")
check("updated_by = joyce after her edit", bool(b) and b[0]["updated_by"] == joyce_id, f"{b}")
check("group_id preserved on update", bool(b) and b[0]["group_id"] == gid, f"{b}")
# a client can't move an item to another group
s, b = http(f"/rest/v1/items?id=eq.{new_id}", "PATCH", {"group_id": str(uuid.uuid4()), "updated_at": later}, jwt=can_jwt, prefer="return=representation")
check("client can't change group_id (trigger pins it)", s == 200 and b and b[0]["group_id"] == gid, f"{s} {b}")

# ---------------------------------------------------------------- stale-write guard still in place
s, b = http(f"/rest/v1/items?id=eq.{new_id}", "PATCH", {"title": "STALE", "updated_at": "2020-01-01T00:00:00Z"}, jwt=can_jwt, prefer="return=representation")
s2, b2 = svc(f"/rest/v1/items?id=eq.{new_id}&select=title")
check("stale replay ignored", b2 and b2[0]["title"] != "STALE", f"{s} {b} / {b2}")

# machine-only edit does not bump updated_at
s, before = svc(f"/rest/v1/items?id=eq.{new_id}&select=updated_at,updated_by")
s, b = svc(f"/rest/v1/items?id=eq.{new_id}", "PATCH", {"image_url": "https://example.com/x.jpg"}, prefer="return=minimal")
s, after = svc(f"/rest/v1/items?id=eq.{new_id}&select=updated_at,updated_by")
check("machine edit leaves updated_at/updated_by alone", before == after, f"{before} -> {after}")

# ---------------------------------------------------------------- stranger
s, b = http("/rest/v1/items", "POST", [dict(row, id=str(uuid.uuid4()), added_by_email=STRANGER)], jwt=str_jwt, prefer="return=minimal")
check("stranger cannot insert", s in (400, 401, 403), f"{s} {b}")
s, b = http(f"/rest/v1/items?id=eq.{new_id}", "PATCH", {"title": "HACKED", "updated_at": later}, jwt=str_jwt, prefer="return=representation")
s2, b2 = svc(f"/rest/v1/items?id=eq.{new_id}&select=title")
check("stranger update touches 0 rows", (b == [] or s in (401, 403, 404)) and b2[0]["title"] != "HACKED", f"{s} {b} / {b2}")
s, b = http(f"/rest/v1/items?id=eq.{new_id}", "DELETE", jwt=str_jwt, prefer="return=representation")
s2, b2 = svc(f"/rest/v1/items?id=eq.{new_id}&select=id")
check("stranger delete touches 0 rows", bool(b2), f"{s} {b} / {b2}")
s, b = http(f"/rest/v1/items?id=eq.{new_id}&select=id", jwt=str_jwt)
check("stranger can't read the row by id", s == 200 and b == [], f"{s} {b}")

# ---------------------------------------------------------------- delete own
for i in (new_id, old_id):
    s, b = http(f"/rest/v1/items?id=eq.{i}", "DELETE", jwt=can_jwt, prefer="return=representation")
    check(f"can deletes test row {i[:8]}", s == 200 and len(b) == 1, f"{s} {b}")

# ---------------------------------------------------------------- apns_tokens
tok = "rlstest" + uuid.uuid4().hex
s, b = http("/rest/v1/apns_tokens", "POST", {"token": tok, "email": CAN}, jwt=can_jwt, prefer="resolution=merge-duplicates,return=minimal")
check("can registers an APNs token (email payload, as the app sends)", s == 201, f"{s} {b}")
s, b = svc(f"/rest/v1/apns_tokens?token=eq.{tok}&select=user_id,email")
if PHASE == "1b": check("1b: token linked to can's user_id by trigger", s == 200 and b and b[0]["user_id"] == can_id, f"{b}")
else: print("INFO 1a: new token user_id =", b[0]["user_id"], "(no trigger yet; 0017 backfills)")
s, b = http(f"/rest/v1/apns_tokens?token=eq.{tok}&select=token", jwt=str_jwt)
check("stranger can't read can's token", s == 200 and b == [], f"{s} {b}")
s, b = http("/rest/v1/apns_tokens", "POST", {"token": "strangertok" + uuid.uuid4().hex, "email": STRANGER}, jwt=str_jwt, prefer="return=minimal")
if PHASE == "1a":
    check("1a: stranger can't register a token (not a member)", s in (401, 403), f"{s} {b}")
else:
    check("1b: stranger may register a token (own row, no group needed)", s == 201, f"{s} {b}")
    svc("/rest/v1/apns_tokens?token=like.strangertok*", "DELETE")
s, b = http(f"/rest/v1/apns_tokens?token=eq.{tok}", "DELETE", jwt=can_jwt, prefer="return=representation")
check("can deletes own token", s == 200 and len(b) == 1, f"{s} {b}")

# ---------------------------------------------------------------- digest is gone (0024)
if PHASE == "1a":
    s, b = http("/rest/v1/digest_schedule?select=day_of_week,hour,minute&limit=1", jwt=can_jwt)
    check("1a: can reads singleton digest_schedule", s == 200 and len(b) == 1, f"{s} {b}")
    s, b = http("/rest/v1/digest_schedule?id=eq.true", "PATCH", {"minute": 15}, jwt=joyce_jwt, prefer="return=minimal")
    print("INFO 1a: singleton PATCH ->", s, "(1b retires the singleton; 0024 drops per-group schedules too)")
    http("/rest/v1/digest_schedule?id=eq.true", "PATCH", {"minute": 0}, jwt=joyce_jwt, prefer="return=minimal")
else:
    s, b = http("/rest/v1/digest_schedule?select=*", jwt=can_jwt)
    check("1b: singleton digest_schedule is gone", s == 404, f"{s}")
    s, b = http("/rest/v1/digest_schedules?select=*", jwt=can_jwt)
    check("0024: digest_schedules is gone", s == 404, f"{s}")
    s, b = http("/rest/v1/digest_runs?select=*", jwt=can_jwt)
    check("0024: digest_runs is gone", s == 404, f"{s}")

# ---------------------------------------------------------------- groups / profiles / entitlements (1a tables)
s, b = http("/rest/v1/groups?select=id,name" + (",feed_token" if PHASE == "1b" else ""), jwt=can_jwt)
check("can reads own group", s == 200 and len(b) == 1 and b[0]["id"] == gid, f"{s} {b}")
if PHASE == "1b":
    check("1b: group has a feed_token", bool(b) and len(b[0].get("feed_token") or "") == 32, f"{b}")
s, b = http("/rest/v1/groups?select=id", jwt=str_jwt); check("stranger reads 0 groups", s == 200 and b == [], f"{s} {b}")
s, b = http("/rest/v1/profiles?select=user_id,display_name", jwt=joyce_jwt); check("joyce reads both profiles", s == 200 and len(b) == 2, f"{s} {b}")
s, b = http("/rest/v1/profiles?select=user_id", jwt=str_jwt); check("stranger reads 0 profiles", s == 200 and b == [], f"{s} {b}")
s, b = http("/rest/v1/entitlements?select=*", jwt=can_jwt); check("can reads group entitlements", s == 200 and len(b) >= 1, f"{s} {b}")
s, b = http("/rest/v1/group_members?select=user_id", jwt=can_jwt); check("can sees 2 group members", s == 200 and len(b) == 2, f"{s} {b}")

# ---------------------------------------------------------------- helpers
s, b = http("/rest/v1/rpc/current_group_id", "POST", {}, jwt=can_jwt); check("current_group_id() for can", s == 200 and b == gid, f"{s} {b}")
s, b = http("/rest/v1/rpc/current_group_id", "POST", {}, jwt=str_jwt); check("current_group_id() null for stranger", s == 200 and b is None, f"{s} {b}")
s, b = http("/rest/v1/rpc/is_member", "POST", {}, jwt=can_jwt)
check(("1a: is_member() still exists" if PHASE == "1a" else "1b: is_member() is gone"), (s == 200 and b is True) if PHASE == "1a" else s == 404, f"{s} {b}")

# ---------------------------------------------------------------- 1b-only: member cap, dispatcher
if PHASE == "1b":
    rows = sql(f"""
      do $$
      declare i int; uid uuid; g uuid := '{gid}';
      begin
        for i in 1..3 loop
          uid := gen_random_uuid();
          insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
          values (uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cap' || i || '@example.com', '', now(), now(), now(), '{{}}', '{{}}');
          begin
            -- From 0021 a new auth user is provisioned into a personal group;
            -- one group per user means that row goes before the cap insert.
            delete from public.group_members where user_id = uid;
            insert into public.group_members (group_id, user_id) values (g, uid);
            raise notice 'inserted member %', i;
          exception when check_violation then
            raise notice 'CAP HIT at member %', i;
          end;
        end loop;
      end $$;
      select count(*) as n from public.group_members where group_id = '{gid}';""")
    check("1b: 4-member cap enforced (2 existing + 2 more, 3rd refused)", isinstance(rows, list) and rows and rows[0]["n"] == 4, f"{rows}")
    sql(f"delete from public.group_members where user_id in (select id from auth.users where email like 'cap%@example.com'); delete from auth.users where email like 'cap%@example.com';")
    # 0021 leaves the cap users' empty personal groups and profile tombstones behind.
    sql("delete from public.groups g where not exists (select 1 from public.group_members m where m.group_id = g.id) and not exists (select 1 from public.items i where i.group_id = g.id) and g.id <> (select id from public.groups order by created_at limit 1)")
    sql("delete from public.profiles p where not exists (select 1 from auth.users u where u.id = p.user_id)")
    rows = sql(f"select count(*) as n from public.group_members where group_id = '{gid}'")
    check("1b: cap test cleaned up", rows and rows[0]["n"] == 2, f"{rows}")

    rows = sql("select column_name from information_schema.columns where table_name='items' and column_name='remind_at'")
    check("0024: items.remind_at exists", bool(rows), f"{rows}")
    rows = sql("select to_regclass('public.reminder_runs') as r")
    check("0024: reminder_runs exists", rows and rows[0]["r"] is not None, f"{rows}")
    rows = sql("select public.dispatch_reminders() as fired")
    check("0024: dispatcher runs", isinstance(rows, list) and rows and isinstance(rows[0].get("fired"), int) and rows[0]["fired"] >= 0, f"{rows}")
    rows = sql("select count(*) as n from public.items where group_id is null")
    check("1b: items.group_id NOT NULL", rows and rows[0]["n"] == 0, f"{rows}")
    rows = sql("select to_regclass('public.members') as m, to_regclass('public.digests') as d, to_regclass('public.push_subscriptions') as p")
    check("1b: members/digests/push_subscriptions dropped", rows and all(v is None for v in rows[0].values()), f"{rows}")

print()
print(f"{len(failures)} failure(s)" if failures else "ALL PASS", f"— phase {PHASE}")
for f in failures: print("  -", f)
sys.exit(1 if failures else 0)
