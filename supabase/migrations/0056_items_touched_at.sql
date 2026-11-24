-- 0056: items.touched_at, so a phone can pull only what changed.
--
-- updated_at can't serve: it's the person's edit time, it stays put for
-- machine fills (a thumbnail, a colour, 0015), and an old build can send
-- one from its own clock. touched_at is the server's clock of the row's
-- last write of any kind, set here and nowhere else.
--
-- Existing rows all get the time of this migration (a constant default:
-- no table rewrite). Every app opens with a whole snapshot before it
-- trusts the column, and keeps taking one a day for rows that are gone.

alter table public.items add column if not exists touched_at timestamptz not null default now();

create index if not exists items_group_touched on public.items (group_id, touched_at);

create or replace function public.items_mark_touched() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.touched_at := clock_timestamp();
  return new;
end;
$$;

-- Last of the BEFORE triggers (they run by name), so a write the stale
-- guard drops never moves the clock.
drop trigger if exists items_zzz_touched on public.items;
create trigger items_zzz_touched
  before insert or update on public.items
  for each row execute function public.items_mark_touched();
