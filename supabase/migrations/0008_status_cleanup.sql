-- Idempotent cleanup of statuses removed from the product surface.
-- Enum values stay (Postgres can't easily drop them); rows are normalized.

update public.items
set status = 'saved'::public.item_status
where status in ('inbox'::public.item_status, 'planned'::public.item_status);

update public.items
set planned_for = null
where planned_for is not null;
