-- Plan pings share the notify debounce with save pings. A topic keeps the
-- "added" ping's ten minutes from swallowing a plan made right after.
alter table public.notify_recent add column if not exists topic text not null default 'save';
alter table public.notify_recent drop constraint if exists notify_recent_pkey;
alter table public.notify_recent add primary key (group_id, item_id, actor, topic);
