-- Everyone: at most ten new saves a day, fifty in a Plus group.
--
-- The only daily limit people hear about, and the same however the save
-- arrived: a link, a screenshot, the share sheet, Siri, typed in by hand.
-- It counts what each person added, not their group: one busy member
-- doesn't use up anyone else's day. A save deleted again stops counting,
-- so deleting one frees its slot. The day is the group's home day, the
-- clock every "today" in the app is read on.
--
-- Like the category cap (0030), the trigger judges transitions, not rows:
-- only a brand-new row, or the undelete of one this person added today.
-- Every other write passes, so routine upserts and edits keep syncing.
-- The insert pass of a merge-duplicates upsert stands aside when the id
-- already exists and lets the update pass decide.
--
-- Only client writes are judged (role `authenticated` or `anon`); server
-- functions run as the service role or set `app.bypass_cap`.
--
-- The app mirrors this (DailyCap.swift) so the Plus drawer shows before a
-- save is refused. Hint `plus_required` on the free plan, `daily_max` on
-- Plus, so the app knows which to say.
--
-- Also: a per-person count of searches that weren't saves (`vague`), so
-- the parse endpoint can answer repeat searches without a full lookup.

create index if not exists items_created_by_created_at_idx
  on public.items (created_by, created_at)
  where deleted_at is null;

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

drop trigger if exists items_zz_daily_adds on public.items;
create trigger items_zz_daily_adds
  before insert or update on public.items
  for each row execute function public.enforce_daily_adds();

alter table public.usage_daily add column if not exists vague int not null default 0;

create or replace function public.bump_vague(p_user_id uuid, p_day date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  total integer;
begin
  insert into public.usage_daily as u (user_id, day, vague)
  values (p_user_id, p_day, 1)
  on conflict (user_id, day) do update set vague = u.vague + 1
  returning u.vague into total;
  return total;
end;
$$;

revoke execute on function public.bump_vague(uuid, date) from public, anon, authenticated;
