-- First-run starters: three real things to go to in the new person's home
-- city, offered as tappable chips on the first-save page. One web-search
-- model call per city, cached here so the second person in Lisbon pays
-- nothing and waits for nothing. Service role only — clients go through
-- the `starters` function.
create table if not exists public.starter_cache (
  key text primary key,            -- lower("locality|country")
  locality text not null,
  country text not null,
  payload jsonb not null,          -- { starters: [{ title, url, kind }] }
  fetched_at timestamptz not null default now()
);

alter table public.starter_cache enable row level security;
revoke all on public.starter_cache from anon, authenticated;
