-- Fixes from the code health audit.
--
--   dispatch_reminders    the 10:00 hour only pings groups with a preset
--                         due; a hand-picked 23:46–23:59 is reached by the
--                         first ticks after midnight instead of never
--   register_apns_token   a token moves to whoever signs in on that phone
--                         (it used to collide with the last account's row)
--   unregister_device     sign-out takes this phone off both push lists
--   bump_usage            the daily AI counter in one statement, so two
--                         calls at once don't lose a count or fail
--   item-images           listing is for the group's own folder; files
--                         stay readable by URL (the bucket is public)

create or replace function public.register_apns_token(
  p_token text,
  p_device_id text,
  p_build integer,
  p_platform text default 'ios'
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

  delete from public.apns_tokens
  where token = p_token
     or (user_id = auth.uid() and (device_id = p_device_id or device_id is null));

  insert into public.apns_tokens (token, user_id, device_id, build, platform)
  values (p_token, auth.uid(), p_device_id, p_build, coalesce(p_platform, 'ios'));
end;
$$;

revoke execute on function public.register_apns_token(text, text, integer, text) from public, anon;
grant execute on function public.register_apns_token(text, text, integer, text) to authenticated;

create or replace function public.unregister_device(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  delete from public.apns_tokens where user_id = auth.uid() and device_id = p_device_id;
  delete from public.activity_tokens where user_id = auth.uid() and device_id = p_device_id;
  delete from public.live_activity_tokens where user_id = auth.uid() and device_id = p_device_id;
end;
$$;

revoke execute on function public.unregister_device(text) from public, anon;
grant execute on function public.unregister_device(text) to authenticated;

create or replace function public.bump_usage(p_user_id uuid, p_day date, p_kind text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  total integer;
begin
  if p_kind not in ('parse', 'locate', 'suggest') then
    raise exception 'unknown kind %', p_kind using errcode = 'check_violation';
  end if;
  insert into public.usage_daily as u (user_id, day, parse, locate, suggest)
  values (
    p_user_id, p_day,
    (p_kind = 'parse')::int, (p_kind = 'locate')::int, (p_kind = 'suggest')::int
  )
  on conflict (user_id, day) do update set
    parse = u.parse + excluded.parse,
    locate = u.locate + excluded.locate,
    suggest = u.suggest + excluded.suggest
  returning u.parse + u.locate + u.suggest into total;
  return total;
end;
$$;

revoke execute on function public.bump_usage(uuid, date, text) from public, anon, authenticated;

drop policy if exists "anyone can read item images" on storage.objects;
drop policy if exists "members read item images" on storage.objects;
create policy "members read item images"
on storage.objects for select
to authenticated
using (
  bucket_id = 'item-images'
  and (storage.foldername(name))[1] = public.current_group_id()::text
);

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

    -- A preset (no time of its own) waiting for the 10:00 hour.
    due := false;
    if now_minutes >= 10 * 60 and now_minutes <= 10 * 60 + 59 then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.remind_at = local_now::date
          and i.remind_time is null
          and i.deleted_at is null
          and i.status = 'saved'
          and not exists (
            select 1 from public.reminder_runs rr
            where rr.item_id = i.id and rr.remind_at = i.remind_at
              and rr.status = 'completed'
          )
      ) into due;
    end if;

    -- A hand-picked time that has come round. The last quarter hour of the
    -- day is only reached by the first ticks after midnight.
    if not due then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.remind_time is not null
          and (
            (i.remind_at = local_now::date and i.remind_time <= local_now::time)
            or (now_minutes < 60 and i.remind_at = local_now::date - 1)
          )
          and i.deleted_at is null
          and i.status = 'saved'
          and not exists (
            select 1 from public.reminder_runs rr
            where rr.item_id = i.id and rr.remind_at = i.remind_at
              and rr.status = 'completed'
          )
      ) into due;
    end if;

    -- A Live Activity to start: a day-of reminder whose moment has come,
    -- not yet started, before 23:00, and someone with the switch on.
    if not due and now_minutes < 23 * 60 then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.remind_at = local_now::date
          and i.deleted_at is null
          and i.status = 'saved'
          and (
            (i.reminder_anchor = 'custom' and i.remind_time <= local_now::time)
            or (i.reminder_anchor is distinct from 'custom' and i.reminder_offset_days = 0
                and now_minutes >= 10 * 60)
          )
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

    -- One to end: within a tick of its end, a day gone by, or the save
    -- no longer on its reminder day.
    if not due then
      select exists (
        select 1 from public.live_activity_runs lr
        left join public.items i on i.id = lr.item_id
        where lr.group_id = g.group_id
          and lr.ended_at is null
          and (
            lr.remind_at < local_now::date
            or coalesce(lr.ends_at, now()) <= now() + interval '15 minutes'
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
