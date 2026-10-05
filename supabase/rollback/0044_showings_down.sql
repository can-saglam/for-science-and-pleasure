-- Rollback for 0044_showings.sql: 0042's guard and transfer_items, then the column.

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

alter table public.items drop constraint if exists items_showings_chk;
alter table public.items drop column if exists showings;

delete from supabase_migrations.schema_migrations where version = '0044';
