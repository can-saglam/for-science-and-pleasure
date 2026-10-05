-- Undoes 0045: back to 0042's items_default_group and 0043's daily count.

drop trigger if exists items_pin_inserted_at on public.items;
drop function if exists public.items_pin_inserted_at();

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

create or replace function public.enforce_daily_adds()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  tz text;
  day_start timestamptz;
  cap int;
  n int;
begin
  if coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
     or coalesce(current_setting('app.bypass_cap', true), '') = 'on'
     or me is null
     or new.group_id is null
     or new.deleted_at is not null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if exists (select 1 from public.items where id = new.id) then
      return new;
    end if;
  elsif old.deleted_at is null then
    return new;
  end if;

  select coalesce(g.home_timezone, 'Europe/London') into tz from public.groups g where g.id = new.group_id;
  tz := coalesce(tz, 'Europe/London');
  day_start := date_trunc('day', now() at time zone tz) at time zone tz;

  if tg_op = 'UPDATE' and (old.created_by is distinct from me or old.created_at < day_start) then
    return new;
  end if;

  cap := case when public.group_is_plus(new.group_id) then 50 else 10 end;

  -- Two of this person's phones saving at once: one wins the last slot.
  perform pg_advisory_xact_lock(hashtext('daily_adds|' || me::text));

  select count(*) into n
  from public.items i
  where i.created_by = me
    and i.id <> new.id
    and i.deleted_at is null
    and i.created_at >= day_start;

  if n >= cap then
    raise exception 'daily_full'
      using errcode = 'P0001', detail = cap::text,
            hint = case when cap = 10 then 'plus_required' else 'daily_max' end;
  end if;
  return new;
end;
$$;

alter table public.items drop column if exists inserted_at;
