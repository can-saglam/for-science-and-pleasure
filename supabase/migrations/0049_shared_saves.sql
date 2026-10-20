-- A save sent to someone outside the library: wegocan.com/s/<token> opens a
-- copy of its card (title, place, dates, photo, link — never notes, plans
-- or reminders), on the web or straight into the app. One link per save
-- per sender: sharing it again refreshes the copy and keeps the link.
-- Only the share function (service role) reads or writes it.
create table public.shared_saves (
  token text primary key,
  item_id uuid not null,
  created_by uuid not null references auth.users (id) on delete cascade,
  card jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (created_by, item_id)
);

alter table public.shared_saves enable row level security;
