-- One row per parse: which route it took, how it ended, how long each
-- stage ran and what the model call used. For seeing where parses fail,
-- slow down or cost the most, week by week. Nothing that was parsed and
-- nobody's id: per-person counts stay in usage_daily, which deleting an
-- account clears.
--
-- Written by the parse function with the service role; no policies, so
-- no client can read or write it.

create table if not exists public.parse_runs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  -- What came in: 'link', 'text' or 'image'.
  source text not null,
  -- How it was read: 'page', 'search', 'maps', 'social' or 'image'. Null
  -- when it ended before the model was asked.
  route text,
  -- 'card', 'vague' (the model's verdict), 'gate' (the quick search check
  -- answered), 'social_unreadable', 'unreadable', 'slow', 'too_large',
  -- 'over_quota' or 'error'.
  outcome text not null,
  charged boolean not null default false,
  model text,
  searches int,
  input_tokens int,
  output_tokens int,
  stop_reason text,
  read_ms int,
  model_ms int,
  lookups_ms int,
  -- When the model's fields reached the phone.
  early_ms int,
  total_ms int not null,
  -- Lookups dropped to make the deadline.
  skipped text[],
  has_photo boolean,
  has_pin boolean
);
create index if not exists parse_runs_at on public.parse_runs (at desc);
alter table public.parse_runs enable row level security;

create or replace view public.parse_runs_weekly with (security_invoker = true) as
select
  date_trunc('week', at)::date as week,
  coalesce(route, '—') as route,
  count(*) as runs,
  count(*) filter (where outcome = 'card') as cards,
  count(*) filter (where outcome in ('vague', 'gate')) as searches_refused,
  count(*) filter (where outcome in ('unreadable', 'slow', 'error')) as failed,
  count(*) filter (where charged) as charged,
  percentile_cont(0.5) within group (order by total_ms)::int as p50_ms,
  percentile_cont(0.9) within group (order by total_ms)::int as p90_ms,
  percentile_cont(0.5) within group (order by early_ms)::int as p50_early_ms,
  avg(input_tokens)::int as avg_input_tokens,
  avg(output_tokens)::int as avg_output_tokens,
  sum(searches) as web_searches,
  round(avg(case when has_photo then 1.0 else 0.0 end) filter (where outcome = 'card'), 2) as photo_rate
from public.parse_runs
group by 1, 2
order by 1 desc, 2;
revoke all on public.parse_runs_weekly from anon, authenticated;
