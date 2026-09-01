-- Stale-write guard for items.
--
-- Incident (31 Aug 2026): a dormant client (the retired web PWA) came back
-- online holding a weeks-old copy of an item and wrote the whole row back,
-- resurrecting an old title and kind. The touch trigger stamped the write
-- with a fresh updated_at, so the regression looked like a new edit and
-- last-write-wins spread it to every device.
--
-- Fix: when an UPDATE arrives carrying an updated_at older than what the
-- row already has, it is a replay of stale data — drop it silently instead
-- of letting history run backwards. Writes that don't touch updated_at
-- (soft deletes, single-field patches) keep working: NEW.updated_at equals
-- OLD.updated_at in that case, which passes the check.
--
-- items gets its own trigger function; the shared touch_updated_at() stays
-- as-is for other tables.

create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
begin
  if new.updated_at is not null
     and old.updated_at is not null
     and new.updated_at < old.updated_at then
    return null; -- stale replay: keep the stored row
  end if;
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists items_touch_updated_at on public.items;
create trigger items_touch_updated_at
  before update on public.items
  for each row execute function public.items_touch_and_guard();
