-- Plans: the day (and maybe the time) the group means to go. On the day,
-- the save goes on everyone's Lock Screen an hour before the time (10:00
-- without one), and any phone the Live Activity didn't reach gets one
-- notification instead. A plan stands in for a reminder on the same day.
--
--   items.plan_on / plan_time   the day, and HH:MM on the home clock
--   items.planned_by            who set it: stamped from the login, never
--                               taken from the payload
--   live_activity_runs.source   'reminder' or 'plan', and the plan's time,
--                               so a moved plan ends and starts again
--   plan_runs                   one plan notification per (save, day, time)
--
-- Setting or moving a plan bumps updated_at (so it syncs) but isn't an
-- edit: "Edited by" stays on whoever last changed the save itself.
-- Clients that don't know the columns (builds before 94) leave them out
-- of their upserts, so plans survive their writes.

alter table public.items add column if not exists plan_on date;
alter table public.items add column if not exists plan_time time;
alter table public.items add column if not exists planned_by uuid;

alter table public.items drop constraint if exists items_plan_time_chk;
alter table public.items
  add constraint items_plan_time_chk check (plan_time is null or plan_on is not null);

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
    new.added_by_email = coalesce(nullif(auth.jwt() ->> 'email', ''), new.added_by_email);
    new.planned_by = case when new.plan_on is null then null else auth.uid() end;
  end if;
  return new;
end;
$$;

-- As 0041, plus the plan columns.
create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
declare
  machine_only boolean;
  plan_only boolean;
  exempt text[] := array['updated_at', 'updated_by', 'created_by', 'group_id', 'image_url', 'color', 'place_id'];
  plan text[] := array['plan_on', 'plan_time', 'planned_by'];
begin
  if current_setting('cwg.membership', true) = 'on' then
    return new;
  end if;

  if new.updated_at is not null
     and old.updated_at is not null
     and new.updated_at < old.updated_at then
    return null; -- stale replay: keep the stored row
  end if;

  new.group_id = old.group_id;
  new.created_by = old.created_by;
  new.added_by_email = old.added_by_email;

  if new.venue is distinct from old.venue
     or new.address is distinct from old.address
     or (new.kind = 'place' and new.title is distinct from old.title) then
    if new.place_id is not distinct from old.place_id then
      new.place_id = null;
    end if;
  elsif new.place_id is null then
    new.place_id = old.place_id;
  end if;

  if new.plan_on is null then
    new.plan_time = null;
  end if;
  if new.plan_on is distinct from old.plan_on or new.plan_time is distinct from old.plan_time then
    new.planned_by = case when new.plan_on is null then null else coalesce(auth.uid(), old.planned_by) end;
  else
    new.planned_by = old.planned_by;
  end if;

  if old.lat is null and old.lng is null then
    exempt := exempt || array['lat', 'lng'];
  end if;

  machine_only :=
    (to_jsonb(new) - exempt) = (to_jsonb(old) - exempt);
  plan_only := not machine_only
    and (to_jsonb(new) - exempt - plan) = (to_jsonb(old) - exempt - plan);

  if machine_only then
    new.updated_at = old.updated_at;
    new.updated_by = old.updated_by;
  elsif plan_only then
    new.updated_at = now();
    new.updated_by = old.updated_by;
  else
    new.updated_at = now();
    new.updated_by = coalesce(auth.uid(), old.updated_by);
  end if;
  return new;
end;
$$;

alter table public.live_activity_runs
  add column if not exists source text not null default 'reminder';
alter table public.live_activity_runs
  add column if not exists plan_time time;

create table if not exists public.plan_runs (
  item_id uuid not null references public.items(id) on delete cascade,
  plan_on date not null,
  plan_time time,
  group_id uuid not null,
  sent_at timestamptz not null default now(),
  primary key (item_id, plan_on)
);
alter table public.plan_runs enable row level security;

-- ---------------------------------------------------------------------------
-- transfer_items: as 0028, plus place_id (missed until now) and the plan
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
        place_id, plan_on, plan_time, planned_by
      )
      select kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        raw_input, source, notes, added_by_email, created_by, updated_by, dst,
        created_at, updated_at,
        reminder_offset_days, reminder_anchor, remind_at, remind_time,
        place_id, plan_on, plan_time, planned_by
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
-- dispatch_reminders: as 0034, plus plans. A reminder on a planned day
-- waits for the plan instead; a plan's moment is an hour before its time
-- (10:00 without one), and a Live Activity whose plan moved or went ends.
-- send-reminders re-checks everything, so a spare ping is harmless.
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
$$;

revoke all on function public.dispatch_reminders() from public;
revoke all on function public.dispatch_reminders() from anon;
revoke all on function public.dispatch_reminders() from authenticated;
