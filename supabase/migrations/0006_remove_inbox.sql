-- New captures now go straight into the shared library.
update public.items
set status = 'saved'::public.item_status
where status = 'inbox';

alter table public.items
  alter column status set default 'saved'::public.item_status;
