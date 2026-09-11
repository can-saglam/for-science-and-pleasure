-- Per-event Remind: one opt-in reminder on a dated save, shared with the
-- group, fired at 10:00 on the home clock. Replaces the weekly digest push
-- and the local last-chance notifier.
--
--   items              offset + anchor + computed fire day (client-written)
--   reminder_runs      send-state, so a phone upsert cannot wipe "already sent"
--   dispatch_reminders 15-minute cron → send-reminders for groups in the hour
--
-- Digest runtime (schedules, runs, dispatcher, vault helper) goes away.
-- The Shortcut pull (`functions/digest`) stays; it never used these tables.

-- ---------------------------------------------------------------------------
-- Item columns
-- ---------------------------------------------------------------------------

alter table public.items
  add column if not exists reminder_offset_days int,
  add column if not exists reminder_anchor text,
  add column if not exists remind_at date;

alter table public.items drop constraint if exists items_reminder_offset_days_chk;
alter table public.items
  add constraint items_reminder_offset_days_chk
  check (reminder_offset_days is null or reminder_offset_days in (0, 1, 3, 7));

alter table public.items drop constraint if exists items_reminder_anchor_chk;
alter table public.items
  add constraint items_reminder_anchor_chk
  check (reminder_anchor is null or reminder_anchor in ('starts_on', 'ends_on'));

-- All three, or none. A half-written reminder must not reach the cron.
alter table public.items drop constraint if exists items_reminder_shape_chk;
alter table public.items
  add constraint items_reminder_shape_chk
  check (
    (reminder_offset_days is null and reminder_anchor is null and remind_at is null)
    or
    (reminder_offset_days is not null and reminder_anchor is not null and remind_at is not null)
  );

create index if not exists items_remind_at_idx
  on public.items (group_id, remind_at)
  where remind_at is not null and deleted_at is null and status = 'saved';

-- ---------------------------------------------------------------------------
-- Send-state (service role only — phones never touch this)
-- ---------------------------------------------------------------------------

create table if not exists public.reminder_runs (
  item_id uuid not null references public.items (id) on delete cascade,
  remind_at date not null,
  status text not null check (status in ('running', 'completed', 'failed')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  error text,
  primary key (item_id, remind_at)
);

alter table public.reminder_runs enable row level security;

-- ---------------------------------------------------------------------------
-- Join/leave must copy the new columns
-- ---------------------------------------------------------------------------

create or replace function public.transfer_items(src uuid, dst uuid, copy boolean)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  moved int := 0;
  r record;
  twin uuid;
  twin_notes text;
begin
  perform set_config('cwg.membership', 'on', true);

  for r in select * from public.items where group_id = src and deleted_at is null loop
    twin := null;
    if r.url is not null then
      select id, notes into twin, twin_notes from public.items t
      where t.group_id = dst and t.deleted_at is null
        and public.normalise_url(t.url) = public.normalise_url(r.url)
      order by created_at limit 1;
    end if;

    if twin is not null then
      if r.notes is not null and btrim(r.notes) <> '' and position(r.notes in coalesce(twin_notes, '')) = 0 then
        update public.items set notes = nullif(concat_ws(E'\n\n', nullif(twin_notes, ''), r.notes), '')
        where id = twin;
      end if;
      if not copy then
        delete from public.items where id = r.id;
      end if;
    elsif copy then
      insert into public.items (
        kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        raw_input, source, notes, added_by_email, created_by, updated_by, group_id,
        created_at, updated_at,
        reminder_offset_days, reminder_anchor, remind_at
      )
      select kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        raw_input, source, notes, added_by_email, created_by, updated_by, dst,
        created_at, updated_at,
        reminder_offset_days, reminder_anchor, remind_at
      from public.items where id = r.id;
      moved := moved + 1;
    else
      update public.items set group_id = dst where id = r.id;
      moved := moved + 1;
    end if;
  end loop;

  if not copy then
    update public.items set group_id = dst where group_id = src;
  end if;
  return moved;
end;
$$;

-- ---------------------------------------------------------------------------
-- Provisioning no longer seeds a digest schedule
-- ---------------------------------------------------------------------------

create or replace function public.provision_personal_group(uid uuid, p_home_from uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
  src public.groups;
begin
  insert into public.profiles (user_id) values (uid)
  on conflict (user_id) do nothing;

  -- Home is inherited from the group being left (if any): someone leaving
  -- "Can & Joyce" still lives in London.
  if p_home_from is not null then
    select * into src from public.groups where id = p_home_from;
  end if;

  insert into public.groups (name, created_by, home_locality, home_country, home_timezone, home_lat, home_lng)
  values ('Saves', uid, src.home_locality, src.home_country, coalesce(src.home_timezone, 'Europe/London'), src.home_lat, src.home_lng)
  returning id into gid;

  insert into public.group_members (user_id, group_id) values (uid, gid);
  return gid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Drop digest runtime
-- ---------------------------------------------------------------------------

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job from cron.job where jobname = 'weekly-digest-london';
  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
end;
$$;

drop function if exists public.dispatch_weekly_digest();
drop function if exists public.provision_weekly_digest_cron(text, text);

drop table if exists public.digest_runs;
drop table if exists public.digest_schedules;

-- ---------------------------------------------------------------------------
-- Reminders cron
-- ---------------------------------------------------------------------------

create or replace function public.provision_reminders_cron(
  p_function_url text,
  p_cron_secret text
)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;

  delete from vault.secrets
  where name in ('reminders_url', 'reminders_cron_secret');

  perform vault.create_secret(
    p_function_url,
    'reminders_url',
    'Can We Go send-reminders Edge Function URL'
  );
  perform vault.create_secret(
    p_cron_secret,
    'reminders_cron_secret',
    'Can We Go reminders cron authentication'
  );
end;
$$;

revoke all on function public.provision_reminders_cron(text, text) from public;
revoke all on function public.provision_reminders_cron(text, text) from anon;
revoke all on function public.provision_reminders_cron(text, text) from authenticated;
grant execute on function public.provision_reminders_cron(text, text) to service_role;

-- pg_cron every 15 minutes. For each group whose home clock is inside
-- 10:00–10:59, ping send-reminders. The edge function re-checks the window
-- and dedups with reminder_runs.
create or replace function public.dispatch_reminders()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  g record;
  local_now timestamp;
  now_minutes int;
  function_url text;
  cron_secret text;
  fired bigint := 0;
begin
  select decrypted_secret into function_url
  from vault.decrypted_secrets where name = 'reminders_url' limit 1;
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'reminders_cron_secret' limit 1;
  if function_url is null or cron_secret is null then
    raise warning 'Reminders Vault secrets have not been provisioned';
    return 0;
  end if;

  for g in
    select id as group_id,
           coalesce(nullif(btrim(home_timezone), ''), 'Europe/London') as timezone
    from public.groups
  loop
    begin
      local_now := timezone(g.timezone, now());
    exception when others then
      local_now := timezone('Europe/London', now());
    end;

    now_minutes := extract(hour from local_now)::int * 60
                 + extract(minute from local_now)::int;
    if now_minutes < 10 * 60 or now_minutes > 10 * 60 + 59 then
      continue;
    end if;

    perform net.http_post(
      url := function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', cron_secret
      ),
      body := jsonb_build_object(
        'group_id', g.group_id,
        'scheduled_for', local_now::date
      )
    );
    fired := fired + 1;
  end loop;

  return fired;
end;
$$;

revoke all on function public.dispatch_reminders() from public;
revoke all on function public.dispatch_reminders() from anon;
revoke all on function public.dispatch_reminders() from authenticated;

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job from cron.job where jobname = 'reminders-home';
  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;

  perform cron.schedule(
    'reminders-home',
    '*/15 * * * *',
    'select public.dispatch_reminders();'
  );
end;
$$;
