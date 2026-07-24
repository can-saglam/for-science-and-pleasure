-- Planning is now suggestion-only and is no longer persisted on items.
update public.items
set
  status = case when status = 'planned' then 'saved'::public.item_status else status end,
  planned_for = null
where status = 'planned' or planned_for is not null;

drop index if exists public.items_planned_for_idx;
