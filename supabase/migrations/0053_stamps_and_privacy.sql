-- Server stamps, members' privacy, and account deletion in one piece.
--
-- 1. Server-side stamps on a new save (was parked as 0045), so a client
--    can't backdate its way past the daily limit (0043 counted the
--    client's own created_at), and can't freeze a row with a future
--    updated_at (0042's stale-write guard would then drop every later edit
--    to it, silently).
--
--      items.inserted_at   when the server took the row in: stamped on a
--                          client insert, never changed after. The daily
--                          count reads it. created_at stays what the app
--                          shows, so an offline save keeps the day it was
--                          made.
--
--    Rows from before this have no inserted_at and are counted by
--    created_at, as they were. A group move's copies (transfer_items) and
--    server-side writes keep their created_at as inserted_at, so a move
--    never uses up anyone's day. The app never sends inserted_at.
--
-- 2. Members' email addresses are no longer kept with saves. Every save
--    carries created_by, which is what the app shows ("Added by"), so the
--    address only ever travelled to the other members' phones. Client
--    inserts get none, and the stored ones are cleared. Builds still send
--    the column, so it stays, always null.
--
-- 3. A member can read their group and change its home (the city sheet),
--    nothing else: feed_token, invite_code, name and the rest only change
--    through the membership API. A home timezone Postgres doesn't know
--    keeps the previous one, or the cap triggers' `at time zone` would fail
--    every save in the group.
--
-- 4. delete_account_data: everything account deletion does in the
--    database, in one transaction, so it can't half-succeed. The login
--    itself, storage and the "left" ping stay in the function.
--
-- Rollback: rollback/0053_stamps_and_privacy_down.sql (the cleared emails
-- don't come back).

-- 1. Stamps --------------------------------------------------------------

alter table public.items add column if not exists inserted_at timestamptz;

-- As 0042, plus the stamps, minus the email. Only client writes (the same
-- test 0043 uses) are stamped with the server's clock.
create or replace function public.items_default_group()
returns trigger
language plpgsql
as $$
begin
  if new.group_id is null then
    new.group_id = public.current_group_id();
  end if;
  if auth.uid() is not null then
    new.created_by = auth.uid();
    new.updated_by = auth.uid();
    new.added_by_email = null;
    new.planned_by = case when new.plan_on is null then null else auth.uid() end;
  end if;
  if coalesce(current_setting('role', true), 'none') in ('authenticated', 'anon')
     and coalesce(current_setting('cwg.membership', true), '') <> 'on' then
    new.inserted_at = now();
    if new.created_at is null or new.created_at > now() then
      new.created_at = now();
    end if;
    if new.updated_at is null or new.updated_at > now() then
      new.updated_at = now();
    end if;
  else
    new.inserted_at = coalesce(new.created_at, now());
  end if;
  return new;
end;
$$;

-- Fires before items_touch_updated_at (alphabetical), so a write that only
-- tries to move inserted_at reads as no change at all.
create or replace function public.items_pin_inserted_at()
returns trigger
language plpgsql
as $$
begin
  new.inserted_at = old.inserted_at;
  return new;
end;
$$;

drop trigger if exists items_pin_inserted_at on public.items;
create trigger items_pin_inserted_at
  before update on public.items
  for each row execute function public.items_pin_inserted_at();

-- As 0043, counting by when the server took each save in.
create or replace function public.enforce_daily_adds()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  tz text;
  day_start timestamptz;
  cap int;
  n int;
begin
  if coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
     or coalesce(current_setting('app.bypass_cap', true), '') = 'on'
     or me is null
     or new.group_id is null
     or new.deleted_at is not null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if exists (select 1 from public.items where id = new.id) then
      return new;
    end if;
  elsif old.deleted_at is null then
    return new;
  end if;

  select coalesce(g.home_timezone, 'Europe/London') into tz from public.groups g where g.id = new.group_id;
  tz := coalesce(tz, 'Europe/London');
  day_start := date_trunc('day', now() at time zone tz) at time zone tz;

  if tg_op = 'UPDATE'
     and (old.created_by is distinct from me or coalesce(old.inserted_at, old.created_at) < day_start) then
    return new;
  end if;

  cap := case when public.group_is_plus(new.group_id) then 50 else 10 end;

  -- Two of this person's phones saving at once: one wins the last slot.
  perform pg_advisory_xact_lock(hashtext('daily_adds|' || me::text));

  select count(*) into n
  from public.items i
  where i.created_by = me
    and i.id <> new.id
    and i.deleted_at is null
    and coalesce(i.inserted_at, i.created_at) >= day_start;

  if n >= cap then
    raise exception 'daily_full'
      using errcode = 'P0001', detail = cap::text,
            hint = case when cap = 10 then 'plus_required' else 'daily_max' end;
  end if;
  return new;
end;
$$;

-- 2. No emails on saves --------------------------------------------------

-- Housekeeping, not an edit: the guard lets it through untouched and
-- updated_at stays, so nobody's pending change loses to it.
do $$
begin
  perform set_config('cwg.membership', 'on', true);
  update public.items set added_by_email = null where added_by_email is not null;
end;
$$;

-- 3. Groups: read, and edit the home ----------------------------------------

revoke all on table public.groups from anon, authenticated;
grant select on table public.groups to authenticated;
grant update (home_locality, home_country, home_timezone, home_lat, home_lng)
  on table public.groups to authenticated;

create or replace function public.groups_check_timezone()
returns trigger
language plpgsql
as $$
begin
  if new.home_timezone is not null
     and btrim(new.home_timezone) <> ''
     and (tg_op = 'INSERT' or new.home_timezone is distinct from old.home_timezone)
     and not exists (select 1 from pg_timezone_names where name = new.home_timezone) then
    -- Apple's zone list can run ahead of the server's. Keep the city and
    -- the zone it had (London for a new group) rather than refuse the
    -- save or let one name stop the tick for every group.
    raise warning 'unknown timezone %, kept the previous one', new.home_timezone;
    new.home_timezone := case when tg_op = 'UPDATE' then old.home_timezone else 'Europe/London' end;
  end if;
  return new;
end;
$$;

drop trigger if exists groups_check_timezone on public.groups;
create trigger groups_check_timezone
  before insert or update of home_timezone on public.groups
  for each row execute function public.groups_check_timezone();

-- 4. Account deletion ----------------------------------------------------

-- Everything in the database that is the person's, gone together. A shared
-- library stays with whoever remains (their codes go, the feed URL
-- changes); a solo one goes with them. Saves they made in other libraries
-- stay, without them. Rows that reference the login (devices, tokens,
-- entitlements, city asks, shared copies) go when the login is deleted.
create or replace function public.delete_account_data(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
  others int := 0;
begin
  select group_id into gid from public.group_members where user_id = p_user;

  if gid is not null then
    select count(*) - 1 into others from public.group_members where group_id = gid;
    if others > 0 then
      delete from public.group_members where user_id = p_user;
      delete from public.group_invites where group_id = gid and created_by = p_user;
      update public.groups
         set feed_token = replace(gen_random_uuid()::text, '-', '')
       where id = gid;
    else
      delete from public.live_activity_runs where group_id = gid;
      delete from public.notify_recent where group_id = gid;
      delete from public.items where group_id = gid;
      delete from public.group_invites where group_id = gid;
      delete from public.group_members where group_id = gid;
      delete from public.groups where id = gid;
    end if;
  end if;

  delete from public.usage_daily where user_id = p_user;
  delete from public.invite_attempts where user_id = p_user;
  delete from public.notify_recent where actor = p_user;
  delete from public.profiles where user_id = p_user;

  return jsonb_build_object('group_id', gid, 'others', greatest(others, 0));
end;
$$;

revoke all on function public.delete_account_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_account_data(uuid) to service_role;
