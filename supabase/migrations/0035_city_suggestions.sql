-- Suggestions for the empty library tabs and the first-save page: a pool
-- of real things on in a home city (events, from a web search, checked like
-- a save) and places worth going to. One row per city and kind, refreshed
-- when someone asks after it's gone stale — events weekly, places every
-- two weeks — so a city nobody opens costs nothing. Service role only;
-- clients go through the `suggestions` function.
create table if not exists public.city_suggestions (
  key text not null,                 -- lower("locality|country")
  kind text not null check (kind in ('event', 'place')),
  locality text not null,
  country text not null,
  payload jsonb not null default '{"items": []}'::jsonb,
  fetched_at timestamptz,            -- null until the first refresh lands
  refreshing_since timestamptz,      -- one refresh at a time per row
  primary key (key, kind)
);

alter table public.city_suggestions enable row level security;
revoke all on public.city_suggestions from anon, authenticated;
