"""Edge-function battery against a staging copy after the groups flip (see README.md)."""
import json, os, sys, uuid, urllib.request

URL, ANON, SVC = os.environ["SURL"], os.environ["SANON"], os.environ["SSVC"]
creds = json.load(open(os.environ.get("CREDS_FILE", "/tmp/stg_creds.json")))
STRANGER = "stranger@example.com"
CAN = [e for e in creds if e != STRANGER][0]
failures = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if (detail and not cond) else ""))
    if not cond: failures.append(name)

def call(path, method="GET", body=None, headers=None):
    h = {"apikey": ANON, "Content-Type": "application/json", "User-Agent": "curl/8"}
    h.update(headers or {})
    r = urllib.request.Request(URL + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp: return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()

def login(email):
    s, b = call("/auth/v1/token?grant_type=password", "POST", {"email": email, "password": creds[email]})
    return json.loads(b)["access_token"]
can, stranger = login(CAN), login(STRANGER)
bearer = lambda t: {"Authorization": f"Bearer {t}"}
svc = {"apikey": SVC, "Authorization": f"Bearer {SVC}"}

s, b = call("/rest/v1/groups?select=id,feed_token", headers=svc); g = json.loads(b)[0]
s, b = call("/rest/v1/items?select=id&deleted_at=is.null&status=eq.saved&limit=1", headers=svc); item_id = json.loads(b)[0]["id"]

# notify-save
s, b = call("/functions/v1/notify-save", "POST", {"item_id": item_id}, bearer(can));      check("notify-save: member → 200 (APNs unconfigured → 0 sent)", s == 200 and json.loads(b).get("sent") == 0, f"{s} {b}")
s, b = call("/functions/v1/notify-save", "POST", {"item_id": item_id}, bearer(stranger)); check("notify-save: stranger → 403", s == 403, f"{s} {b}")
s, b = call("/functions/v1/notify-save", "POST", {"item_id": item_id});                   check("notify-save: no JWT → 403", s in (401, 403), f"{s} {b}")

# gates on parse / locate / suggest (no model key on staging: anything but 403 means the gate let the member through)
for fn, body in (("parse", {"text": "Tate Modern late, Friday"}), ("locate", {"items": [{"id": item_id, "title": "x"}]}), ("suggest", {"date": "2026-09-12"})):
    s, b = call(f"/functions/v1/{fn}", "POST", body, bearer(stranger)); check(f"{fn}: stranger → 403", s == 403, f"{s} {b[:120]}")
    s, b = call(f"/functions/v1/{fn}", "POST", body, bearer(can));      check(f"{fn}: member passes the gate", s != 403 and s != 401, f"{s} {b[:120]}")
s, b = call("/functions/v1/parse", "POST", {"text": "x"}, {"x-ingest-secret": os.environ.get("STG_INGEST_SECRET", "stg-ingest-secret")}); check("parse: ingest secret still accepted", s not in (401, 403), f"{s} {b[:120]}")

# calendar / digest feeds
s, tok = call(f"/functions/v1/calendar?key={g['feed_token']}");            check("calendar: group feed_token → ICS", s == 200 and "BEGIN:VCALENDAR" in tok, f"{s} {tok[:80]}")
s, leg = call("/functions/v1/calendar?key=stg-ingest-secret");             check("calendar: legacy secret → founding group's ICS (identical)", s == 200 and leg == tok, f"{s}")
s, b = call("/functions/v1/calendar?key=nope");                            check("calendar: bad key → 401", s == 401, f"{s}")
s, b = call("/functions/v1/calendar");                                     check("calendar: no key → 401", s == 401, f"{s}")
s, b = call(f"/functions/v1/digest?key={g['feed_token']}");                check("digest: feed_token → text", s == 200 and "text" in json.loads(b), f"{s} {b[:80]}")
s, b = call("/functions/v1/digest?key=nope");                              check("digest: bad key → 401", s == 401, f"{s}")

# ingest (Shortcut path)
s, b = call("/functions/v1/ingest", "POST", {"text": "ingest test row", "added_by": STRANGER}, {"x-ingest-secret": os.environ.get("STG_INGEST_SECRET", "stg-ingest-secret")}); check("ingest: unknown added_by → 400", s == 400, f"{s} {b}")
s, b = call("/functions/v1/ingest", "POST", {"text": "ingest test row", "added_by": CAN.upper()}, {"x-ingest-secret": os.environ.get("STG_INGEST_SECRET", "stg-ingest-secret")})
ok = s == 200 and json.loads(b).get("ok"); check("ingest: member email (any case) → saved", ok, f"{s} {b}")
if ok:
    nid = json.loads(b)["id"]
    s, row = call(f"/rest/v1/items?id=eq.{nid}&select=group_id,created_by,updated_by,source", headers=svc); row = json.loads(row)[0]
    check("ingest: row stamped with group + creator", row["group_id"] == g["id"] and row["created_by"] and row["created_by"] == row["updated_by"], f"{row}")
    call(f"/rest/v1/items?id=eq.{nid}", "DELETE", headers=svc)
s, b = call("/functions/v1/ingest", "POST", {"text": "x", "added_by": CAN}, {"x-ingest-secret": "wrong"}); check("ingest: wrong secret → 401", s == 401, f"{s}")

# send-reminders
cron = os.environ.get("STG_CRON_SECRET", "stg-cron-secret")
s, b = call("/functions/v1/send-reminders", "POST", {}, {"x-cron-secret": "wrong"}); check("send-reminders: wrong secret → 401", s == 401, f"{s}")
s, b = call("/functions/v1/send-reminders", "POST", {"group_id": g["id"], "at": "2026-12-15T09:00:00Z"}, {"x-cron-secret": cron})
r = json.loads(b) if s == 200 else {}; check("send-reminders: outside 10:00 window → skipped", s == 200 and r.get("groups", [{}])[0].get("skipped") is True, f"{s} {b}")

due_id = str(uuid.uuid4())
due = {
    "id": due_id, "kind": "event", "status": "saved", "title": "Reminder battery",
    "source": "app", "group_id": g["id"], "starts_on": "2026-12-22", "ends_on": "2026-12-22",
    "reminder_offset_days": 7, "reminder_anchor": "starts_on", "remind_at": "2026-12-15",
    "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
}
s, b = call("/rest/v1/items", "POST", [due], headers={**svc, "Prefer": "return=minimal"})
check("send-reminders: planted a due item", s in (201, 200), f"{s} {b}")
# 10:15 GMT on 15 Dec is 10:15 Europe/London (GMT).
s, b = call("/functions/v1/send-reminders", "POST", {"group_id": g["id"], "at": "2026-12-15T10:15:00Z"}, {"x-cron-secret": cron})
r = json.loads(b) if s == 200 else {}
g0 = (r.get("groups") or [{}])[0]
check("send-reminders: due item in window → 1 item, 0 pushes (APNs unconfigured)", s == 200 and g0.get("items") == 1 and g0.get("apnsSent") == 0, f"{s} {b}")
s, b = call("/functions/v1/send-reminders", "POST", {"group_id": g["id"], "at": "2026-12-15T10:30:00Z"}, {"x-cron-secret": cron})
r = json.loads(b) if s == 200 else {}
g0 = (r.get("groups") or [{}])[0]
check("send-reminders: already-run skip", s == 200 and g0.get("items") == 0 and g0.get("skipped") is not True, f"{s} {b}")
s, b = call("/functions/v1/send-reminders", "POST", {"force": True, "group_id": g["id"]}, {"x-cron-secret": cron})
r = json.loads(b) if s == 200 else {}
g0 = (r.get("groups") or [{}])[0]
check("send-reminders: force → ran, 0 pushes", s == 200 and "apnsSent" in g0 and g0.get("apnsSent") == 0, f"{s} {b}")
s, b = call(f"/rest/v1/reminder_runs?item_id=eq.{due_id}&select=status", headers=svc)
runs = json.loads(b) if s == 200 else []
check("send-reminders: force left no running leftover", s == 200 and all(x.get("status") != "running" for x in runs), f"{s} {b}")
call(f"/rest/v1/reminder_runs?item_id=eq.{due_id}", "DELETE", headers=svc)
call(f"/rest/v1/items?id=eq.{due_id}", "DELETE", headers=svc)

print(); print(f"{len(failures)} failure(s)" if failures else "ALL PASS", "— functions")
for f in failures: print("  -", f)
sys.exit(1 if failures else 0)
