-- Live Activities, revised: only on the day itself, from the moment the
-- reminder goes off. "Morning of" presets (offset 0) start with the 10:00
-- push, hand-picked reminders at their own time; each runs up to eight
-- hours (the system's cap) and is gone by midnight. The earlier reminders
-- (a week / 3 days / 1 day before) stay notifications only.
--
--   live_activity_runs.ends_at   when this one leaves the Lock Screen
--   unregister_activity_token    the Settings switch, per device
--   dispatch_reminders           start and end rules as above

alter table public.live_activity_runs
  add column if not exists ends_at timestamptz;

create or replace function public.unregister_activity_token(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  delete from public.activity_tokens where user_id = auth.uid() and device_id = p_device_id;
end;
$$;

revoke execute on function public.unregister_activity_token(text) from public, anon;
grant execute on function public.unregister_activity_token(text) to authenticated;

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
