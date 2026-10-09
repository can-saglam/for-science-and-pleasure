-- One row per suggestions refresh: which city and kind, how it went, and
-- what the model calls used, so the cost of keeping cities fresh can be
-- read week by week rather than guessed. Cities aren't personal; nobody's
-- id is stored.
--
-- Written by the suggestions function with the service role; no
-- policies, so no client can read or write it.

create table if not exists public.suggestion_runs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  key text not null,                 -- lower("locality|country")
  kind text not null check (kind in ('event', 'place')),
  -- 'kept' (a new pool landed), 'empty' (nothing passed; old pool kept)
  -- or 'error'.
  outcome text not null,
  -- The city counted as busy, so its events refresh every three days.
  busy boolean not null default false,
  proposed int,
  kept int,
  model text,
  searches int,
  input_tokens int,
  output_tokens int,
  total_ms int not null
);
create index if not exists suggestion_runs_at on public.suggestion_runs (at desc);
alter table public.suggestion_runs enable row level security;

create or replace view public.suggestion_runs_weekly with (security_invoker = true) as
select
  date_trunc('week', at)::date as week,
  kind,
  count(*) as runs,
  count(distinct key) as cities,
  count(*) filter (where busy) as busy_runs,
  count(*) filter (where outcome <> 'kept') as failed,
  round(avg(kept), 1) as avg_kept,
  sum(searches) as web_searches,
  sum(input_tokens) as input_tokens,
  sum(output_tokens) as output_tokens,
  percentile_cont(0.5) within group (order by total_ms)::int as p50_ms
from public.suggestion_runs
group by 1, 2
order by 1 desc, 2;
revoke all on public.suggestion_runs_weekly from anon, authenticated;

-- How many people have this city as their library's home, keyed the way
-- the suggestions pool is (trimmed, spaces collapsed, lower case). One
-- library per person, so a plain count is people.
create or replace function public.city_people(p_key text)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from public.groups g
  join public.group_members m on m.group_id = g.id
  where lower(regexp_replace(btrim(coalesce(g.home_locality, '')), '\s+', ' ', 'g'))
     || '|'
     || lower(regexp_replace(btrim(coalesce(nullif(g.home_country, ''), g.home_locality, '')), '\s+', ' ', 'g'))
     = p_key;
$$;
revoke all on function public.city_people(text) from public, anon, authenticated;
grant execute on function public.city_people(text) to service_role;
