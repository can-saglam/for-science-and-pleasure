-- Housekeeping: what isn't needed goes, the reminder tick only visits
-- groups with something due, and the weekly cost view reads 0053's rows.
--
-- 1. purge_old_rows(), nightly at 03:41 UTC:
--      saves deleted more than 90 days ago (their runs and tokens cascade).
--        A deleted row only tells other phones to drop the save; one that
--        hasn't synced since keeps it, and an edit there would bring it
--        back. 90 days makes that rare until sync drops what the server
--        no longer has.
--      invite attempts older than 30 days (the guard reads the last hour)
--      notification debounce rows older than 7 days
--      parse and suggestion runs older than 180 days
--    and items.raw_input goes: only the retired Shortcut ingest wrote it,
--    no build sends it, and transfer_items stops copying it.
--    transfer_items also stops failing on a URL twin (an enum compared
--    with '' since 0026: a join or leave with a duplicate link errored).
--
-- 2. dispatch_reminders() loops only over groups with a reminder or plan
--    within a day of today (any timezone) or a Live Activity still open:
--    the per-group checks are 0042's, unchanged. Plans get the index
--    reminders already have.
--
-- 3. suggestion_runs_weekly: suggestion_jobs now writes a 'started' row
--    before a run spends and an 'extras' row for label/describe/card spend.
--    Runs and failures count neither; 'started' left behind is a run that
--    never finished; tokens, searches and cost count everything.
--
-- Rollback: rollback/0054_housekeeping_down.sql (raw_input comes back
-- empty).

-- 1. Purge -----------------------------------------------------------------

create or replace function public.purge_old_rows()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  saves int;
  attempts int;
  debounce int;
  parses int;
  suggestions int;
begin
  delete from public.items where deleted_at < now() - interval '90 days';
  get diagnostics saves = row_count;
  delete from public.invite_attempts where at < now() - interval '30 days';
  get diagnostics attempts = row_count;
  delete from public.notify_recent where sent_at < now() - interval '7 days';
  get diagnostics debounce = row_count;
  delete from public.parse_runs where at < now() - interval '180 days';
  get diagnostics parses = row_count;
  delete from public.suggestion_runs where at < now() - interval '180 days';
  get diagnostics suggestions = row_count;
  return jsonb_build_object(
    'saves', saves, 'invite_attempts', attempts, 'notify_recent', debounce,
    'parse_runs', parses, 'suggestion_runs', suggestions
  );
end;
$$;

revoke all on function public.purge_old_rows() from public, anon, authenticated;

select cron.unschedule('purge-nightly') where exists (select 1 from cron.job where jobname = 'purge-nightly');
select cron.schedule('purge-nightly', '41 3 * * *', 'select public.purge_old_rows();');

-- As 0044, without raw_input, and without the status line: nullif(status, '')
-- compares an enum with '' and failed every merge of a URL twin since 0026.
create or replace function public.transfer_items(src uuid, dst uuid, copy boolean)
returns integer
language plpgsql
security definer
set search_path = public
as $$
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
        source, notes, added_by_email, created_by, updated_by, group_id,
        created_at, updated_at,
        reminder_offset_days, reminder_anchor, remind_at, remind_time,
        place_id, plan_on, plan_time, planned_by, showings
      )
      select kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        source, notes, added_by_email, created_by, updated_by, dst,
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
$$;

alter table public.items drop column if exists raw_input;

-- 2. Reminder tick ---------------------------------------------------------

create index if not exists items_plan_on_idx
  on public.items (group_id, plan_on)
  where plan_on is not null and deleted_at is null and status = 'saved';

-- As 0042, visiting fewer groups.
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
  has_tokens boolean;
  -- Every zone's date is within a day of UTC's.
  utc_today date := (now() at time zone 'utc')::date;
begin
  select decrypted_secret into function_url
  from vault.decrypted_secrets where name = 'reminders_url' limit 1;
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'reminders_cron_secret' limit 1;
  if function_url is null or cron_secret is null then
    raise warning 'Reminders Vault secrets have not been provisioned';
    return 0;
  end if;

  -- Only groups with something that could be due: a reminder or plan
  -- within a day of today in any timezone (a reminder's last quarter hour
  -- is reached after midnight, so the day before too), or a Live Activity
  -- still open. Everyone else has nothing for the checks below to find.
  for g in
    select gr.id as group_id,
           coalesce(nullif(btrim(gr.home_timezone), ''), 'Europe/London') as timezone
    from public.groups gr
    where exists (
            select 1 from public.items i
            where i.group_id = gr.id
              and i.remind_at is not null and i.deleted_at is null and i.status = 'saved'
              and i.remind_at between utc_today - 2 and utc_today + 1
          )
       or exists (
            select 1 from public.items i
            where i.group_id = gr.id
              and i.plan_on is not null and i.deleted_at is null and i.status = 'saved'
              and i.plan_on between utc_today - 1 and utc_today + 1
          )
       or exists (
            select 1 from public.live_activity_runs lr
            where lr.group_id = gr.id and lr.ended_at is null
          )
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
$$;

-- 3. Weekly suggestion costs ---------------------------------------------

create or replace view public.suggestion_runs_weekly with (security_invoker = true) as
select date_trunc('week', at)::date as week,
       kind,
       count(*) filter (where outcome <> 'extras') as runs,
       count(distinct key) as cities,
       count(*) filter (where busy and outcome <> 'extras') as busy_runs,
       count(*) filter (where outcome not in ('kept', 'extras', 'started')) as failed,
       round(avg(kept) filter (where outcome <> 'extras'), 1) as avg_kept,
       sum(searches) as web_searches,
       sum(input_tokens) as input_tokens,
       sum(output_tokens) as output_tokens,
       (percentile_cont(0.5) within group (order by total_ms::double precision)
         filter (where outcome not in ('extras', 'started')))::integer as p50_ms,
       count(*) filter (where outcome = 'started') as unfinished,
       round(sum(coalesce(input_tokens, 0) * 3 + coalesce(output_tokens, 0) * 15)::numeric / 1e6
             + sum(coalesce(searches, 0)) * 0.01, 2) as cost_usd
from public.suggestion_runs
group by 1, 2
order by 1 desc, 2;
