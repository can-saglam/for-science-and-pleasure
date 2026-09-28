-- Opening hours. A save keeps the Google place its hours come from; the
-- hours themselves are asked for each time they're shown (Google's terms
-- allow keeping a place ID, not its hours). Filling one in is machine work
-- like a thumbnail: no "Edited by", no updated_at bump.
--
-- Clients that don't know the column (builds before 93) leave it out of
-- their upserts, so it survives their writes. A client that sends null for
-- a save whose place it never learnt doesn't clear it either. Moving the
-- save (a new venue, address, or a place's name) does, unless the same
-- write brings a new place ID from a fresh parse.
alter table public.items add column if not exists place_id text;

alter table public.usage_daily add column if not exists hours int not null default 0;

create or replace function public.bump_hours(p_user_id uuid, p_day date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  total integer;
begin
  insert into public.usage_daily as u (user_id, day, hours)
  values (p_user_id, p_day, 1)
  on conflict (user_id, day) do update set hours = u.hours + 1
  returning u.hours into total;
  return total;
end;
$$;

revoke execute on function public.bump_hours(uuid, date) from public, anon, authenticated;

create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
declare
  machine_only boolean;
  exempt text[] := array['updated_at', 'updated_by', 'created_by', 'group_id', 'image_url', 'color', 'place_id'];
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

  if old.lat is null and old.lng is null then
    exempt := exempt || array['lat', 'lng'];
  end if;

  machine_only :=
    (to_jsonb(new) - exempt) = (to_jsonb(old) - exempt);

  if machine_only then
    new.updated_at = old.updated_at;
    new.updated_by = old.updated_by;
  else
    new.updated_at = now();
    new.updated_by = coalesce(auth.uid(), old.updated_by);
  end if;
  return new;
end;
$$;
