-- Phase 1b — flip security to groups (launch plan).
--
-- 1a put the group model in place without changing who could read what.
-- This migration makes the group the unit of access:
--
--   * items.group_id becomes NOT NULL; every items policy moves from
--     is_member() (a fixed list of two emails) to is_in_group(group_id).
--   * items.created_by is added (backfilled from added_by_email) so "Added
--     by" no longer depends on the retiring `members` table.
--   * apns_tokens are owned by user_id (filled server-side from the JWT),
--     scoped to the owner.
--   * The singleton digest_schedule is retired; the dispatcher walks
--     digest_schedules and fires each group at its own time in its own
--     timezone. digest_runs is keyed by (group_id, week_start).
--   * Each group gets a feed_token for its calendar/digest URLs.
--   * A trigger enforces the 4-member cap.
--   * `members` and is_member() are dropped. Edge functions ship alongside
--     with current_group_id() in their place.
--
-- The tested revert is supabase/rollback/0017_groups_flip_down.sql.
--
-- Precondition, asserted first: no item is without a group. 1a's backfill
-- and trigger guarantee it; if it ever weren't true the whole migration
-- aborts before touching a policy.

do $$
declare orphans int;
begin
  select count(*) into orphans from public.items where group_id is null;
  if orphans > 0 then
    raise exception '1b aborted: % items have no group_id', orphans;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- items
-- ---------------------------------------------------------------------------

alter table public.items
  alter column group_id set not null,
  add column if not exists created_by uuid references auth.users (id) on delete set null;

update public.items i
set created_by = u.id
from auth.users u
where lower(u.email) = lower(i.added_by_email)
  and i.created_by is null;

-- New saves: group, creator and editor from the JWT (extends 1a's trigger).
create or replace function public.items_default_group()
returns trigger
language plpgsql
as $$
begin
  if new.group_id is null then
    new.group_id = public.current_group_id();
  end if;
  if new.created_by is null then
    new.created_by = auth.uid();
  end if;
  if new.updated_by is null then
    new.updated_by = auth.uid();
  end if;
  return new;
end;
$$;

-- created_by joins the columns a row push can't change.
create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
declare
  machine_only boolean;
  exempt text[] := array['updated_at', 'updated_by', 'created_by', 'group_id', 'image_url', 'color'];
begin
  if new.updated_at is not null
     and old.updated_at is not null
     and new.updated_at < old.updated_at then
    return null; -- stale replay: keep the stored row
  end if;

  new.group_id = old.group_id;
  new.created_by = old.created_by;

  machine_only :=
    (to_jsonb(new) - exempt) = (to_jsonb(old) - exempt);

  if machine_only then
    new.updated_at = old.updated_at;
    new.updated_by = old.updated_by;
  else
    new.updated_at = now();
    new.updated_by = coalesce(auth.uid(), old.updated_by);
  end if;
  return new;
end;
$$;

drop policy "members read items" on public.items;
drop policy "members insert items" on public.items;
drop policy "members update items" on public.items;
drop policy "members delete items" on public.items;

-- WITH CHECK runs on the row *after* BEFORE triggers, so a client that
-- sends no group_id passes: items_default_group has filled it in by then.
create policy "group reads its items"
  on public.items for select
  to authenticated
  using (public.is_in_group(group_id));

create policy "group inserts its items"
  on public.items for insert
  to authenticated
  with check (public.is_in_group(group_id));

create policy "group updates its items"
  on public.items for update
  to authenticated
  using (public.is_in_group(group_id))
  with check (public.is_in_group(group_id));

create policy "group deletes its items"
  on public.items for delete
  to authenticated
  using (public.is_in_group(group_id));

-- ---------------------------------------------------------------------------
-- apns_tokens — owned by the user
-- ---------------------------------------------------------------------------

create or replace function public.apns_tokens_default_user()
returns trigger
language plpgsql
as $$
begin
  if new.user_id is null then
    new.user_id = auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists apns_tokens_default_user on public.apns_tokens;
create trigger apns_tokens_default_user
  before insert or update on public.apns_tokens
  for each row execute function public.apns_tokens_default_user();

-- Tokens registered between 1a and now carry only an email (the trigger
-- above didn't exist yet). Link them; drop any that match no account.
update public.apns_tokens t
set user_id = u.id
from auth.users u
where t.user_id is null and lower(u.email) = lower(t.email);
delete from public.apns_tokens where user_id is null;

alter table public.apns_tokens
  alter column user_id set not null,
  alter column email drop not null;

drop policy "members read apns tokens" on public.apns_tokens;
drop policy "members insert apns tokens" on public.apns_tokens;
drop policy "members update apns tokens" on public.apns_tokens;
drop policy "members delete apns tokens" on public.apns_tokens;

create policy "users manage own tokens"
  on public.apns_tokens for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Groups: feed token, member cap
-- ---------------------------------------------------------------------------

alter table public.groups
  add column if not exists feed_token text not null unique default encode(extensions.gen_random_bytes(16), 'hex');

-- Members can read their own group's feed token (it's what the calendar
-- URL is built from). Rotation happens through a function in Phase 2b.
-- (The existing select policy already covers the row; nothing to add.)

create or replace function public.enforce_group_cap()
returns trigger
language plpgsql
as $$
declare n int;
begin
  select count(*) into n from public.group_members where group_id = new.group_id;
  if n >= 4 then
    raise exception 'group is full (4 members)' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists group_members_cap on public.group_members;
create trigger group_members_cap
  before insert on public.group_members
  for each row execute function public.enforce_group_cap();

-- The Shortcut ingest path has no JWT, only an added_by email. This maps
-- it to a (group, user) for the service role; clients can't call it.
create or replace function public.group_for_email(p_email text)
returns table (group_id uuid, user_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select gm.group_id, gm.user_id
  from auth.users u
  join public.group_members gm on gm.user_id = u.id
  where lower(u.email) = lower(p_email)
  order by gm.joined_at
  limit 1;
$$;
revoke execute on function public.group_for_email(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Digest: per group
-- ---------------------------------------------------------------------------

-- digest_runs: one row per (group, week).
alter table public.digest_runs
  add column if not exists group_id uuid references public.groups (id) on delete cascade;
update public.digest_runs
set group_id = (select id from public.groups order by created_at limit 1)
where group_id is null;
alter table public.digest_runs
  alter column group_id set not null,
  drop constraint digest_runs_pkey,
  add primary key (group_id, week_start);

-- The dispatcher: every 15 minutes, for each group whose local clock is
-- inside the hour after its scheduled moment, ping send-digest for that
-- group. send-digest's own digest_runs bookkeeping keeps it to once a week.
create or replace function public.dispatch_weekly_digest()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  sched record;
  local_now timestamp;
  now_minutes int;
  sched_minutes int;
  function_url text;
  cron_secret text;
  fired bigint := 0;
begin
  select decrypted_secret into function_url
  from vault.decrypted_secrets where name = 'weekly_digest_url' limit 1;
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'weekly_digest_cron_secret' limit 1;
  if function_url is null or cron_secret is null then
    raise warning 'Weekly digest Vault secrets have not been provisioned';
    return 0;
  end if;

  for sched in
    select group_id, day_of_week, hour, minute, timezone from public.digest_schedules
  loop
    begin
      local_now := timezone(sched.timezone, now());
    exception when others then
      local_now := timezone('Europe/London', now());
    end;

    if extract(isodow from local_now) <> sched.day_of_week then
      continue;
    end if;
    now_minutes := extract(hour from local_now)::int * 60 + extract(minute from local_now)::int;
    sched_minutes := sched.hour * 60 + sched.minute;
    if now_minutes < sched_minutes or now_minutes > sched_minutes + 59 then
      continue;
    end if;

    perform net.http_post(
      url := function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', cron_secret
      ),
      body := jsonb_build_object(
        'group_id', sched.group_id,
        'scheduled_for', local_now::date
      )
    );
    fired := fired + 1;
  end loop;

  return fired;
end;
$$;

-- Retire the singleton.
drop trigger if exists digest_schedule_mirror on public.digest_schedule;
drop function if exists public.mirror_digest_schedule();
drop table public.digest_schedule;

-- ---------------------------------------------------------------------------
-- Retire `members`
-- ---------------------------------------------------------------------------

-- Two dead tables still reference is_member() in their policies:
-- push_subscriptions (web push, empty since the PWA was retired) and
-- digests (stored digest text; the digest is computed live now and
-- nothing reads it). Drop them rather than rewrite policies for features
-- that no longer exist. Both are in the 7 Sep JSON backup.
drop table if exists public.push_subscriptions;
drop table if exists public.digests;

drop table public.members;   -- takes its own is_member() policy with it
drop function public.is_member();
