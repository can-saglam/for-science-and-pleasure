# Migration rehearsal runbook

Every schema change that touches RLS, drops a table, or adds a `NOT NULL`
gets rehearsed on a throwaway copy of production before it goes up. This
is what caught, in Phase 1b: unlinked APNs tokens that would have failed a
`NOT NULL`, a broken trigger in production, a wrong schema prefix, and a
drop-order dependency. Cost: a few cents of Micro compute for an hour.

Three scripts, no dependencies beyond Python 3 and the Supabase CLI:

| script | target | what it proves |
|---|---|---|
| `rls_battery.py 1a\|1b` | staging | Real users see/write exactly their group; strangers see nothing; triggers stamp `group_id`/`created_by`/`updated_by`; stale-write guard; member cap; dispatcher runs |
| `function_battery.py` | staging | Every edge function's auth gate and group scoping (feeds, ingest, notify, digest) |
| `stranger_probe.py` | **production-safe** | A fresh account can read/insert/update/delete nothing, can't join a group or grant itself Plus; anon gets nothing; function gates hold. Creates and deletes its own user |
| `parse_gate.ts` | **production-safe** (reads only; spends model calls) | Replays a sample of the library's URLs through the *local* extractor with a given home and diffs the cards against what's stored. Run before any prompt change: ship when the diff is noise. `--home "Lisbon\|Portugal\|Europe/Lisbon" --url …` spot-checks another home |

`parse_gate.ts` ran on 8 Sep for the home-string prompts (`deno run -A
supabase/tests/parse_gate.ts --n 14 --seed 42`): 10 clean, 2 soft (area
wording), 2 "hard" that were the *stored* card being wrong (Tate page says
14 July, we had 15) or the source having moved on (Notting Hill Carnival now
advertises 2027). With home = Lisbon, Lisbon museums geocoded in Lisbon with
€ prices, and a London URL stayed in London with the city in its address.

`stranger_probe.py` can be run against production any time (it did run after
1b and after 0018). The other two need a staging copy with the two member
accounts, which the steps below create.

## Rehearsal

```sh
# 0. Fresh backup of production (every table + auth users as JSON).
#    supabase db query --linked --output-format json "select * from public.<t>"  per table

# 1. Throwaway project in the same org/region.
supabase projects create canwego-staging --org-id <org> --db-password "$PW" --region eu-west-2
SUPABASE_DB_PASSWORD="$PW" supabase link --project-ref <staging-ref> --yes

# 2. Schema to the *current production* migration: park the new ones first.
mv supabase/migrations/00NN_new*.sql /tmp/parked/
supabase db push --linked --yes
mv /tmp/parked/*.sql supabase/migrations/

# 3. Data: POST each backup table through PostgREST with the staging service
#    key (Prefer: resolution=merge-duplicates). Create the member accounts via
#    /auth/v1/admin/users with the same emails and fresh passwords, plus
#    stranger@example.com. Write {email: password} to a creds JSON (chmod 600).
#    (1a backfills joined on email, so users must exist before 0016 if
#    starting below it.)

# 4. Baseline — the battery must be green *before* the change.
export SURL=https://<staging-ref>.supabase.co SANON=<anon> SSVC=<service_role> CREDS_FILE=/tmp/stg_creds.json
python3 supabase/tests/rls_battery.py <current-phase>

# 5. Up → test → down → test → up → test.
supabase db push --linked --yes
python3 supabase/tests/rls_battery.py <new-phase>
supabase db query --linked -f supabase/rollback/00NN_*_down.sql
python3 supabase/tests/rls_battery.py <current-phase>
supabase db push --linked --yes --include-all     # --include-all if later migrations exist
python3 supabase/tests/rls_battery.py <new-phase>

# 6. Functions, if they changed.
supabase secrets set INGEST_SECRET=stg-ingest-secret WEEKLY_DIGEST_CRON_SECRET=stg-cron-secret
supabase functions deploy <changed functions> --no-verify-jwt
python3 supabase/tests/function_battery.py

# 7. Optional: run the app itself against staging — point SupabaseAuth.baseURL/anonKey
#    at staging in a *temporary* edit, build to the simulator, write a session into
#    the App Group prefs with `simctl spawn <udid> defaults write <plist path> supabaseSession -data <hex>`.
#    Revert the edit before committing.

# 8. Tear down. Relink to production *before* deploying anything.
supabase projects delete <staging-ref> --yes
supabase link --project-ref gvewzvcvmeztqyfwkgwa --yes
rm /tmp/stg_creds.json
```

## Cutover order

1. Backup.
2. Deploy edge functions first if they are compatible with both schemas (they
   were in 1b: `current_group_id()` existed since 1a).
3. `supabase db push --linked`.
4. `stranger_probe.py` against production; spot-check counts with `db query`.
5. Upload the app build; raise `app_config.min_build` once both phones have it.

## Gotchas learned

- `supabase db query --db-url` uses prepared statements: one statement per
  call. `--linked` (Management API) runs whole files.
- The pooler for London projects is `aws-0-eu-west-2.pooler.supabase.com`.
- `gen_random_bytes` lives in `extensions.`; `safeupdate` rejects any
  `UPDATE`/`DELETE` without a `WHERE` — including inside triggers.
- Drop a table before the function its policies depend on.
- After a rollback, `db push` refuses to re-apply an older migration when a
  newer one is recorded; `--include-all` is the intended path.
- Rollback scripts must delete their row from
  `supabase_migrations.schema_migrations`, and the forward migration must be
  re-runnable over whatever the rollback deliberately leaves behind
  (`if not exists`, `drop trigger if exists`).
