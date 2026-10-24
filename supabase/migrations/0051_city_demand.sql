-- Which cities people actually ask about, so the warm-up (warm-cities)
-- follows demand once the app is live rather than a hand-made list: one
-- row per person, city and day, kept for 120 days (warm-cities prunes).
-- `store` marks an App Store install, not TestFlight or Xcode; the first
-- such row is when the app went live.
--
-- Written by the suggestions function with the service role; no
-- policies, so no client can read or write it.

create table if not exists public.city_asks (
  key text not null,                 -- lower("locality|country"), as city_suggestions
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null default current_date,
  store boolean not null default false,
  primary key (key, user_id, day)
);
create index if not exists city_asks_day on public.city_asks (day);
create index if not exists city_asks_store on public.city_asks (day) where store;
alter table public.city_asks enable row level security;
revoke all on public.city_asks from anon, authenticated;

-- A refresh the warm-up started rather than someone's ask, so its spend
-- can be capped without ever holding up a person waiting for a list.
alter table public.suggestion_runs add column if not exists warm boolean not null default false;

-- Cities asked about since p_since that have a pool to keep (an ask that
-- hit the daily new-city limit has none), most-asked first.
create or replace function public.city_demand(p_since date, p_limit int default 200)
returns table (key text, locality text, country text, askers int, last_day date)
language sql
stable
security definer
set search_path = public
as $$
  select a.key, s.locality, s.country, count(distinct a.user_id)::int, max(a.day)
  from public.city_asks a
  join lateral (
    select c.locality, c.country from public.city_suggestions c where c.key = a.key limit 1
  ) s on true
  where a.day >= p_since
  group by a.key, s.locality, s.country
  order by 4 desc, 5 desc
  limit p_limit;
$$;
revoke all on function public.city_demand(date, int) from public, anon, authenticated;
grant execute on function public.city_demand(date, int) to service_role;
