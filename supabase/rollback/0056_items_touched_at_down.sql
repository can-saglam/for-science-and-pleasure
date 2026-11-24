-- Undoes 0056. Apps fall back to whole snapshots when the column is gone
-- (an incremental pull's 400 resets their pull cursor).

drop trigger if exists items_zzz_touched on public.items;
drop function if exists public.items_mark_touched();
drop index if exists public.items_group_touched;
alter table public.items drop column if exists touched_at;
