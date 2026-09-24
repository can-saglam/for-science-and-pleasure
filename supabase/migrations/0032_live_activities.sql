-- Live Activities on reminder days: from 09:00 on the home clock the save
-- sits on every group member's Lock Screen and Dynamic Island, and it's
-- gone by 18:00. send-reminders starts it with a push-to-start token and
-- ends it with the activity's own update token. The reminder push itself
-- is untouched: this runs beside it, never instead of it.
--
--   activity_tokens        one push-to-start token per (user, device)
--   live_activity_tokens   update tokens of running activities, per save
--   live_activity_runs     one start per (save, reminder day); ended_at
--                          once the end push has gone
--   dispatch_reminders     also pings a group with a start or end due
--
-- All three tables are service-role only (RLS on, no policies); the app
-- writes through the two security-definer registration calls below.

create table if not exists public.activity_tokens (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  token text not null,
  build integer,
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
alter table public.activity_tokens enable row level security;

create table if not exists public.live_activity_tokens (
  token text primary key,
  item_id uuid not null references public.items(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  updated_at timestamptz not null default now()
);
create index if not exists live_activity_tokens_item_idx on public.live_activity_tokens (item_id);
alter table public.live_activity_tokens enable row level security;

create table if not exists public.live_activity_runs (
  item_id uuid not null references public.items(id) on delete cascade,
  remind_at date not null,
  group_id uuid not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  primary key (item_id, remind_at)
);
create index if not exists live_activity_runs_open_idx
  on public.live_activity_runs (group_id) where ended_at is null;
alter table public.live_activity_runs enable row level security;

-- A device's push-to-start token. A token belongs to one account at a
-- time: signing into another account on the same phone moves it.
create or replace function public.register_activity_token(
  p_token text,
  p_device_id text,
  p_build integer default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  if p_token is null or length(p_token) < 32 or p_device_id is null or length(p_device_id) < 8 then
    raise exception 'token and device_id required' using errcode = 'check_violation';
  end if;

  delete from public.activity_tokens
  where token = p_token and not (user_id = auth.uid() and device_id = p_device_id);

  insert into public.activity_tokens (user_id, device_id, token, build)
  values (auth.uid(), p_device_id, p_token, p_build)
  on conflict (user_id, device_id)
  do update set token = excluded.token, build = excluded.build, updated_at = now();
end;
$$;

-- A running activity's update token, so the end push can find it. Only
-- for a save in one of the caller's groups.
create or replace function public.register_live_activity(
  p_item_id uuid,
  p_token text,
  p_device_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  if p_token is null or length(p_token) < 32 or p_device_id is null or length(p_device_id) < 8 then
    raise exception 'token and device_id required' using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.items i
    join public.group_members m on m.group_id = i.group_id
    where i.id = p_item_id and m.user_id = auth.uid()
  ) then
    raise exception 'not a member' using errcode = 'insufficient_privilege';
  end if;

  -- A rotated token replaces the one this device had for the save.
  delete from public.live_activity_tokens
  where item_id = p_item_id and user_id = auth.uid() and device_id = p_device_id and token <> p_token;

  insert into public.live_activity_tokens (token, item_id, user_id, device_id)
  values (p_token, p_item_id, auth.uid(), p_device_id)
  on conflict (token)
  do update set item_id = excluded.item_id, user_id = excluded.user_id,
                device_id = excluded.device_id, updated_at = now();
end;
$$;

revoke execute on function public.register_activity_token(text, text, integer) from public, anon;
grant execute on function public.register_activity_token(text, text, integer) to authenticated;
revoke execute on function public.register_live_activity(uuid, text, text) from public, anon;
grant execute on function public.register_live_activity(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- dispatch_reminders: same as 0028, plus a ping when a Live Activity is
-- due to start (09:00–16:59, a save on its reminder day not yet started,
-- and someone in the group with a push-to-start token) or to end (17:00
-- on, a day gone by, or the save no longer on its reminder day).
-- send-reminders marks runs as it goes, so the pings stop by themselves.
-- ---------------------------------------------------------------------------

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
  due boolean;
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
    due := now_minutes >= 10 * 60 and now_minutes <= 10 * 60 + 59;

    if not due then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.remind_at = local_now::date
          and i.remind_time is not null
          and i.remind_time <= local_now::time
          and i.deleted_at is null
          and i.status = 'saved'
          and not exists (
            select 1 from public.reminder_runs rr
            where rr.item_id = i.id and rr.remind_at = i.remind_at
              and rr.status = 'completed'
          )
      ) into due;
    end if;

    if not due and now_minutes >= 9 * 60 and now_minutes < 17 * 60 then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.remind_at = local_now::date
          and i.deleted_at is null
          and i.status = 'saved'
          and not exists (
            select 1 from public.live_activity_runs lr
            where lr.item_id = i.id and lr.remind_at = i.remind_at
          )
      ) and exists (
        select 1 from public.group_members gm
        join public.activity_tokens t on t.user_id = gm.user_id
        where gm.group_id = g.group_id
      ) into due;
    end if;

    if not due then
      select exists (
        select 1 from public.live_activity_runs lr
        left join public.items i on i.id = lr.item_id
        where lr.group_id = g.group_id
          and lr.ended_at is null
          and (
            lr.remind_at < local_now::date
            or now_minutes >= 17 * 60
            or i.id is null
            or i.deleted_at is not null
            or i.status <> 'saved'
            or i.remind_at is distinct from lr.remind_at
          )
      ) into due;
    end if;

    if not due then
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
