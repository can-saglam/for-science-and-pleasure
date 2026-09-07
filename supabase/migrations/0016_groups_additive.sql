-- Phase 1a — groups in the database, additively (launch plan).
--
-- Everything here is new tables, nullable columns, helper functions and a
-- backfill. Nothing about who can read or write `items` changes: the
-- is_member() policies stay exactly as they are until 1b. A client from
-- before this migration keeps working because every new column is nullable
-- and filled by triggers on the server side.
--
-- Model (see LAUNCH_PLAN.md → Target model):
--   groups          one shared library; has a *home* (locality, country,
--                   timezone, coordinate) that drives parsing context, the
--                   digest clock and the map default.
--   group_members   user → group. A user belongs to exactly one group, so
--                   user_id is the primary key.
--   profiles        display name per user (replaces `members`, which is
--                   keyed by email and is retired in 1b).
--   entitlements    Plus belongs to a *person*, never a group. A group is
--                   Plus whenever any current member holds an active one.
--   digest_schedules per-group weekly digest, alongside the singleton
--                   `digest_schedule` for now; a trigger keeps them in step
--                   until 1b retires the singleton.
--   items.group_id  which library a save belongs to (nullable in 1a).
--   items.updated_by who last *humanly* edited it — stamped server-side
--                   from auth.uid(), never by machine writes.
--   apns_tokens.user_id  tokens keyed by user, not email.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  -- Home: the city, not the borough. Free text, confirmed at onboarding.
  home_locality text,
  home_country text,
  home_timezone text not null default 'Europe/London',
  home_lat double precision,
  home_lng double precision,
  -- Invite codes arrive in Phase 2b; the column exists so 1b's RLS can
  -- reference it without another schema change.
  invite_code text unique,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.group_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  joined_at timestamptz not null default now()
);
create index group_members_group_idx on public.group_members (group_id);

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_colour text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.entitlements (
  user_id uuid primary key references auth.users (id) on delete cascade,
  tier text not null default 'plus' check (tier in ('plus')),
  source text not null check (source in ('app_store', 'founder', 'promo')),
  -- null = never expires (founder / promo). App Store rows carry the
  -- subscription's expiry and are refreshed by the server notification.
  expires_at timestamptz,
  original_transaction_id text,
  updated_at timestamptz not null default now()
);

create table public.digest_schedules (
  group_id uuid primary key references public.groups (id) on delete cascade,
  day_of_week int not null default 4 check (day_of_week between 1 and 7), -- ISO: Mon=1
  hour int not null default 10 check (hour between 0 and 23),
  minute int not null default 0 check (minute between 0 and 59),
  timezone text not null default 'Europe/London',
  updated_at timestamptz not null default now()
);

alter table public.items
  add column group_id uuid references public.groups (id),
  add column updated_by uuid references auth.users (id) on delete set null;
create index items_group_idx on public.items (group_id) where deleted_at is null;

alter table public.apns_tokens
  add column user_id uuid references auth.users (id) on delete cascade;
create index apns_tokens_user_idx on public.apns_tokens (user_id);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The caller's group. security definer so policies on group_members can use
-- it without recursing into themselves.
create or replace function public.current_group_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select group_id from public.group_members where user_id = auth.uid();
$$;

-- 1b's replacement for is_member(). Defined now so the flip is a policy
-- rewrite, not a function hunt.
create or replace function public.is_in_group(gid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select gid is not null and gid = public.current_group_id();
$$;

-- "A group is Plus whenever any current member holds an active entitlement."
create or replace function public.group_is_plus(gid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_members m
    join public.entitlements e on e.user_id = m.user_id
    where m.group_id = gid
      and (e.expires_at is null or e.expires_at > now())
  );
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- New saves land in the writer's group and are attributed to them, whether
-- or not the client knows about either column yet.
create or replace function public.items_default_group()
returns trigger
language plpgsql
as $$
begin
  if new.group_id is null then
    new.group_id = public.current_group_id();
  end if;
  if new.updated_by is null then
    new.updated_by = auth.uid();
  end if;
  return new;
end;
$$;

create trigger items_default_group
  before insert on public.items
  for each row execute function public.items_default_group();

-- Stale-write guard + machine-column rule (0013, 0015), extended:
--   * a human edit stamps updated_by from the JWT — never trusted from the
--     client, never touched by machine-only writes;
--   * group_id can't be blanked or moved by a row push (a full-row upsert
--     from a client that predates the column would otherwise null it).
create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
declare
  machine_only boolean;
  exempt text[] := array['updated_at', 'updated_by', 'group_id', 'image_url', 'color'];
begin
  if new.updated_at is not null
     and old.updated_at is not null
     and new.updated_at < old.updated_at then
    return null; -- stale replay: keep the stored row
  end if;

  -- Membership of a library isn't something a row push gets to change —
  -- once set. (The backfill below sets it for the first time.)
  if old.group_id is not null then
    new.group_id = old.group_id;
  end if;

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

-- While the singleton digest_schedule is still what Settings edits and the
-- dispatcher reads, mirror every change into the per-group rows so 1b can
-- cut over without a data fix-up.
create or replace function public.mirror_digest_schedule()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.digest_schedules
  set day_of_week = new.day_of_week,
      hour = new.hour,
      minute = new.minute,
      updated_at = now();
  return new;
end;
$$;

create trigger digest_schedule_mirror
  after update on public.digest_schedule
  for each row execute function public.mirror_digest_schedule();

create trigger groups_touch_updated_at
  before update on public.groups
  for each row execute function public.touch_updated_at();
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger entitlements_touch_updated_at
  before update on public.entitlements
  for each row execute function public.touch_updated_at();
create trigger digest_schedules_touch_updated_at
  before update on public.digest_schedules
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security — read your own group, edit what's yours to edit.
-- No insert policies yet: creating groups and joining them is Phase 2's
-- sign-up flow and goes through a security-definer function, not raw inserts.
-- ---------------------------------------------------------------------------

alter table public.groups enable row level security;
create policy "members read own group"
  on public.groups for select
  to authenticated
  using (id = public.current_group_id());
create policy "members edit own group"
  on public.groups for update
  to authenticated
  using (id = public.current_group_id())
  with check (id = public.current_group_id());

alter table public.group_members enable row level security;
create policy "members see own group's members"
  on public.group_members for select
  to authenticated
  using (group_id = public.current_group_id());

alter table public.profiles enable row level security;
create policy "members read group profiles"
  on public.profiles for select
  to authenticated
  using (
    user_id in (
      select user_id from public.group_members
      where group_id = public.current_group_id()
    )
  );
create policy "users edit own profile"
  on public.profiles for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy "users create own profile"
  on public.profiles for insert
  to authenticated
  with check (user_id = auth.uid());

alter table public.entitlements enable row level security;
create policy "users read own entitlement"
  on public.entitlements for select
  to authenticated
  using (user_id = auth.uid());

alter table public.digest_schedules enable row level security;
create policy "members read own digest schedule"
  on public.digest_schedules for select
  to authenticated
  using (group_id = public.current_group_id());
create policy "members edit own digest schedule"
  on public.digest_schedules for update
  to authenticated
  using (group_id = public.current_group_id())
  with check (group_id = public.current_group_id());

-- ---------------------------------------------------------------------------
-- Backfill: the founding group.
-- ---------------------------------------------------------------------------

do $$
declare
  gid uuid;
  founder uuid;
begin
  select u.id into founder
  from auth.users u
  where u.email = 'cansaglam@gmail.com';

  insert into public.groups (name, home_locality, home_country, home_timezone, home_lat, home_lng, created_by)
  values ('Can & Joyce', 'London', 'United Kingdom', 'Europe/London', 51.5074, -0.1278, founder)
  returning id into gid;

  -- Everyone in `members` who has actually signed in joins the group.
  insert into public.group_members (user_id, group_id)
  select u.id, gid
  from auth.users u
  join public.members m on lower(m.email) = lower(u.email);

  insert into public.profiles (user_id, display_name)
  select u.id, m.display_name
  from auth.users u
  join public.members m on lower(m.email) = lower(u.email);

  -- Founders are never limited.
  insert into public.entitlements (user_id, tier, source)
  select u.id, 'plus', 'founder'
  from auth.users u
  join public.members m on lower(m.email) = lower(u.email);

  -- The group's digest starts as a copy of the shared schedule.
  insert into public.digest_schedules (group_id, day_of_week, hour, minute, timezone)
  select gid, day_of_week, hour, minute, 'Europe/London'
  from public.digest_schedule
  limit 1;

  -- Every save so far belongs to this library. Straight UPDATE with the
  -- guard trigger: group_id is exempt from the edit check, so updated_at
  -- and updated_by are left exactly as they were.
  update public.items set group_id = gid where group_id is null;

  update public.apns_tokens t
  set user_id = u.id
  from auth.users u
  where lower(u.email) = lower(t.email) and t.user_id is null;
end;
$$;
