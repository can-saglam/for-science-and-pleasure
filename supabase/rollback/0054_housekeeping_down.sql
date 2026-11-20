-- Undoes 0054_housekeeping. raw_input comes back empty.

select cron.unschedule('purge-nightly') where exists (select 1 from cron.job where jobname = 'purge-nightly');
drop function if exists public.purge_old_rows();

alter table public.items add column if not exists raw_input text;
CREATE OR REPLACE FUNCTION public.transfer_items(src uuid, dst uuid, copy boolean)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  moved int := 0;
  r record;
  twin uuid;
  t public.items%rowtype;
begin
  perform set_config('cwg.membership', 'on', true);

  for r in select * from public.items where group_id = src and deleted_at is null loop
    twin := null;
    if r.url is not null then
      select * into t from public.items dest
      where dest.group_id = dst and dest.deleted_at is null
        and public.normalise_url(dest.url) = public.normalise_url(r.url)
      order by dest.created_at limit 1;
      if found then twin := t.id; end if;
    end if;

    if twin is not null then
      update public.items set
        notes = case
          when r.notes is not null and btrim(r.notes) <> ''
               and position(r.notes in coalesce(notes, '')) = 0
          then nullif(concat_ws(E'\n\n', nullif(notes, ''), r.notes), '')
          else notes
        end,
        starts_on = coalesce(starts_on, r.starts_on),
        ends_on = coalesce(ends_on, r.ends_on),
        -- The reminder moves as one: keep the destination's if it has one.
        reminder_offset_days = case when remind_at is null then r.reminder_offset_days else reminder_offset_days end,
        reminder_anchor = case when remind_at is null then r.reminder_anchor else reminder_anchor end,
        remind_time = case when remind_at is null then r.remind_time else remind_time end,
        remind_at = coalesce(remind_at, r.remind_at),
        -- So does the plan.
        plan_time = case when plan_on is null then r.plan_time else plan_time end,
        planned_by = case when plan_on is null then r.planned_by else planned_by end,
        plan_on = coalesce(plan_on, r.plan_on),
        place_id = coalesce(place_id, r.place_id),
        showings = coalesce(showings, r.showings),
        status = coalesce(nullif(status, ''), r.status),
        image_url = coalesce(image_url, r.image_url),
        title = case when title is null or btrim(title) = '' then r.title else title end,
        updated_at = now()
      where id = twin;
      if not copy then
        delete from public.items where id = r.id;
      end if;
    elsif copy then
      insert into public.items (
        kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        raw_input, source, notes, added_by_email, created_by, updated_by, group_id,
        created_at, updated_at,
        reminder_offset_days, reminder_anchor, remind_at, remind_time,
        place_id, plan_on, plan_time, planned_by, showings
      )
      select kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        raw_input, source, notes, added_by_email, created_by, updated_by, dst,
        created_at, updated_at,
        reminder_offset_days, reminder_anchor, remind_at, remind_time,
        place_id, plan_on, plan_time, planned_by, showings
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
$function$;

CREATE OR REPLACE FUNCTION public.dispatch_reminders()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'net'
AS $function$
declare
  g record;
  local_now timestamp;
  now_minutes int;
  function_url text;
  cron_secret text;
  fired bigint := 0;
  due boolean;
  has_tokens boolean;
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

    select exists (
      select 1 from public.group_members gm
      join public.activity_tokens t on t.user_id = gm.user_id
      where gm.group_id = g.group_id
    ) into has_tokens;

    -- A preset (no time of its own) waiting for the 10:00 hour.
    due := false;
    if now_minutes >= 10 * 60 and now_minutes <= 10 * 60 + 59 then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.remind_at = local_now::date
          and i.remind_time is null
          and i.plan_on is distinct from i.remind_at
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
          and i.plan_on is distinct from i.remind_at
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
    if not due and has_tokens and now_minutes < 23 * 60 then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.remind_at = local_now::date
          and i.plan_on is distinct from i.remind_at
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
      ) into due;
    end if;

    -- A plan whose moment has come: its notification not yet sent, or its
    -- Live Activity not yet started.
    if not due then
      select exists (
        select 1 from public.items i
        where i.group_id = g.group_id
          and i.plan_on = local_now::date
          and i.deleted_at is null
          and i.status = 'saved'
          and (
            (i.plan_time is null and now_minutes >= 10 * 60 and now_minutes < 23 * 60)
            or (i.plan_time is not null
                and now_minutes >= extract(hour from i.plan_time)::int * 60
                                  + extract(minute from i.plan_time)::int - 60)
          )
          and (
            not exists (
              select 1 from public.plan_runs pr
              where pr.item_id = i.id and pr.plan_on = i.plan_on
                and pr.plan_time is not distinct from i.plan_time
            )
            or (has_tokens and not exists (
              select 1 from public.live_activity_runs lr
              where lr.item_id = i.id and lr.remind_at = i.plan_on
                and lr.source = 'plan' and lr.plan_time is not distinct from i.plan_time
            ))
          )
      ) into due;
    end if;

    -- One to end: within a tick of its end, a day gone by, or the save
    -- no longer on the reminder or plan it started for.
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
            or (lr.source = 'reminder' and i.remind_at is distinct from lr.remind_at)
            or (lr.source = 'plan' and (i.plan_on is distinct from lr.remind_at
                                        or i.plan_time is distinct from lr.plan_time))
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
$function$;

drop index if exists public.items_plan_on_idx;

drop view if exists public.suggestion_runs_weekly;
create or replace view public.suggestion_runs_weekly with (security_invoker = true) as
select date_trunc('week', at)::date as week,
       kind,
       count(*) as runs,
       count(distinct key) as cities,
       count(*) filter (where busy) as busy_runs,
       count(*) filter (where outcome <> 'kept') as failed,
       round(avg(kept), 1) as avg_kept,
       sum(searches) as web_searches,
       sum(input_tokens) as input_tokens,
       sum(output_tokens) as output_tokens,
       percentile_cont(0.5) within group (order by total_ms::double precision)::integer as p50_ms
from public.suggestion_runs
group by 1, 2
order by 1 desc, 2;

delete from supabase_migrations.schema_migrations where version = '0054';
