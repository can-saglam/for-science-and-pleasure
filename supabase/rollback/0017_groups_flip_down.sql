-- Revert of 0017_groups_flip.sql — back to the 1a state.
--
-- Not a migration: lives in supabase/rollback/ and is run by hand with
-- `supabase db query -f` if 1b has to come down. Tested against a staging
-- copy of production before 1b went up (see LAUNCH_PLAN.md, Phase 1b).
--
-- After running this, redeploy the edge functions from the commit before
-- 1b (they call current_group_id(); the 1a functions call is_member()),
-- and lower app_config.min_build back to 40 if it was raised.
--
-- What comes back:      members + is_member(), the four is_member policies
--                       on items and apns_tokens, the singleton
--                       digest_schedule (copied from the founding group's
--                       row) and its mirror trigger, the singleton digest
--                       dispatcher, digest_runs keyed by week_start alone.
-- What stays:           items.created_by (nullable, harmless), the 4-member
--                       cap, groups.feed_token, the apns user_id trigger.
--                       None of these affect the 1a client.
-- What doesn't return:  push_subscriptions and digests — dead tables with
--                       no readers; restore from the JSON backup if ever
--                       wanted.

-- ---------------------------------------------------------------------------
-- members + is_member()
-- ---------------------------------------------------------------------------

create table public.members (
  email text primary key,
  display_name text,
  created_at timestamptz not null default now()
);

insert into public.members (email, display_name)
select u.email, p.display_name
from auth.users u
join public.group_members gm on gm.user_id = u.id
left join public.profiles p on p.user_id = u.id
where u.email is not null;

alter table public.members enable row level security;

create or replace function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.members
    where email = (auth.jwt() ->> 'email')
  );
$$;

create policy "members can see members"
  on public.members for select
  to authenticated
  using (public.is_member());

-- ---------------------------------------------------------------------------
-- items: nullable group_id, is_member policies, 1a trigger bodies
-- ---------------------------------------------------------------------------

alter table public.items alter column group_id drop not null;

drop policy "group reads its items" on public.items;
drop policy "group inserts its items" on public.items;
drop policy "group updates its items" on public.items;
drop policy "group deletes its items" on public.items;

create policy "members read items"
  on public.items for select
  to authenticated
  using (public.is_member());

create policy "members insert items"
  on public.items for insert
  to authenticated
  with check (public.is_member());

create policy "members update items"
  on public.items for update
  to authenticated
  using (public.is_member())
  with check (public.is_member());

create policy "members delete items"
  on public.items for delete
  to authenticated
  using (public.is_member());

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
    return null;
  end if;

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

-- ---------------------------------------------------------------------------
-- apns_tokens: back to is_member policies, email required again
-- ---------------------------------------------------------------------------

drop policy "users manage own tokens" on public.apns_tokens;

update public.apns_tokens t
set email = u.email
from auth.users u
where u.id = t.user_id and t.email is null;

alter table public.apns_tokens
  alter column email set not null,
  alter column user_id drop not null;

create policy "members read apns tokens"
  on public.apns_tokens for select
  to authenticated
  using (public.is_member());

create policy "members insert apns tokens"
  on public.apns_tokens for insert
  to authenticated
  with check (public.is_member());

create policy "members update apns tokens"
  on public.apns_tokens for update
  to authenticated
  using (public.is_member())
  with check (public.is_member());

create policy "members delete apns tokens"
  on public.apns_tokens for delete
  to authenticated
  using (public.is_member());

-- ---------------------------------------------------------------------------
-- Digest: singleton schedule, singleton dispatcher, runs by week
-- ---------------------------------------------------------------------------

create table public.digest_schedule (
  id boolean primary key default true check (id),
  day_of_week int not null default 4 check (day_of_week between 1 and 7),
  hour int not null default 10 check (hour between 0 and 23),
  minute int not null default 0 check (minute between 0 and 59),
  updated_at timestamptz not null default now()
);

insert into public.digest_schedule (day_of_week, hour, minute)
select s.day_of_week, s.hour, s.minute
from public.digest_schedules s
join public.groups g on g.id = s.group_id
order by g.created_at
limit 1;

insert into public.digest_schedule default values
on conflict do nothing;

alter table public.digest_schedule enable row level security;

create policy "members read digest schedule"
  on public.digest_schedule for select
  to authenticated
  using (public.is_member());

create policy "members update digest schedule"
  on public.digest_schedule for update
  to authenticated
  using (public.is_member())
  with check (public.is_member());

create trigger digest_schedule_touch_updated_at
  before update on public.digest_schedule
  for each row execute function public.touch_updated_at();

create or replace function public.mirror_digest_schedule()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 1a's version had no WHERE and was rejected by safeupdate under
  -- PostgREST; the predicate is what makes the mirror actually work.
  update public.digest_schedules
  set day_of_week = new.day_of_week,
      hour = new.hour,
      minute = new.minute,
      updated_at = now()
  where group_id is not null;
  return new;
end;
$$;

create trigger digest_schedule_mirror
  after update on public.digest_schedule
  for each row execute function public.mirror_digest_schedule();

-- digest_runs back to week_start alone (keep the founding group's rows).
alter table public.digest_runs drop constraint digest_runs_pkey;
delete from public.digest_runs
where group_id <> (select id from public.groups order by created_at limit 1);
alter table public.digest_runs
  add primary key (week_start),
  drop column group_id;

create or replace function public.dispatch_weekly_digest()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  sched record;
  london_now timestamp := timezone('Europe/London', now());
  now_minutes int;
  sched_minutes int;
  function_url text;
  cron_secret text;
  request_id bigint;
begin
  select day_of_week, hour, minute into sched
  from public.digest_schedule
  limit 1;
  if sched is null then
    return null;
  end if;

  if extract(isodow from london_now) <> sched.day_of_week then
    return null;
  end if;

  now_minutes := extract(hour from london_now)::int * 60
               + extract(minute from london_now)::int;
  sched_minutes := sched.hour * 60 + sched.minute;
  if now_minutes < sched_minutes or now_minutes > sched_minutes + 59 then
    return null;
  end if;

  select decrypted_secret into function_url
  from vault.decrypted_secrets where name = 'weekly_digest_url' limit 1;
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'weekly_digest_cron_secret' limit 1;

  if function_url is null or cron_secret is null then
    raise warning 'Weekly digest Vault secrets have not been provisioned';
    return null;
  end if;

  select net.http_post(
    url := function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', cron_secret
    ),
    body := jsonb_build_object('scheduled_for', london_now::date)
  )
  into request_id;

  return request_id;
end;
$$;

-- Forget that 0017 ran, so `supabase db push` would offer it again.
delete from supabase_migrations.schema_migrations where version = '0017';
