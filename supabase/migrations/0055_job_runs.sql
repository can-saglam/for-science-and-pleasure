-- Knowing when the server stops working, and the entitlement check that
-- keeps up as subscribers grow.
--
-- 1. job_runs: every scheduled job records each run, ok or not, with a
--    summary (send-reminders, warm-cities, verify-entitlements from their
--    functions; the reminders tick and purge-nightly from their own cron
--    commands). job-health reads
--    it each morning at 08:00 UTC and pushes an alert to OPS_ALERT_USER_IDS
--    when a job has gone quiet or kept failing. Rows go after 30 days.
--
-- 2. entitlements.checked_at: verify-entitlements now runs hourly and takes
--    the subscribers checked longest ago, a batch at a time, instead of
--    everyone in one nightly pass that stopped at the same place each night
--    once there were more than it could get through.
--
-- 3. metric_reports: MetricKit's daily metrics and crash/hang diagnostics
--    from the app. A phone can add its own reports and never read any
--    back; they go after 90 days, and with the account.
--
-- Rollback: rollback/0055_job_runs_down.sql

create table if not exists public.job_runs (
  id bigint generated always as identity primary key,
  job text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz not null default now(),
  ok boolean not null,
  detail jsonb
);
create index if not exists job_runs_job_finished on public.job_runs (job, finished_at desc);
alter table public.job_runs enable row level security;
revoke all on public.job_runs from anon, authenticated;

alter table public.entitlements add column if not exists checked_at timestamptz;
create index if not exists entitlements_app_store_checked
  on public.entitlements (checked_at nulls first)
  where source = 'app_store' and original_transaction_id is not null;

create table if not exists public.metric_reports (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  received_at timestamptz not null default now(),
  kind text not null check (kind in ('metrics', 'diagnostics')),
  build text check (char_length(build) <= 32),
  payload jsonb not null check (octet_length(payload::text) <= 262144)
);
create index if not exists metric_reports_received on public.metric_reports (received_at);
alter table public.metric_reports enable row level security;
revoke all on public.metric_reports from anon, authenticated;
grant insert (kind, build, payload) on public.metric_reports to authenticated;
create policy "people add their own reports"
  on public.metric_reports for insert
  to authenticated
  with check (user_id = (select auth.uid()));

-- The morning check, called like the other jobs: the reminders function's
-- address with its name swapped, and the shared cron secret.
create or replace function public.dispatch_job_health()
returns void
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  reminders_url text;
  cron_secret text;
begin
  select decrypted_secret into reminders_url
  from vault.decrypted_secrets where name = 'reminders_url' limit 1;
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'reminders_cron_secret' limit 1;
  if reminders_url is null or cron_secret is null then
    raise warning 'Cron Vault secrets have not been provisioned';
    return;
  end if;
  perform net.http_post(
    url := replace(reminders_url, '/send-reminders', '/job-health'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cron_secret),
    body := '{}'::jsonb
  );
end;
$$;
revoke all on function public.dispatch_job_health() from public, anon, authenticated;

select cron.unschedule('entitlements-nightly') where exists (select 1 from cron.job where jobname = 'entitlements-nightly');
select cron.unschedule('entitlements-hourly') where exists (select 1 from cron.job where jobname = 'entitlements-hourly');
select cron.schedule('entitlements-hourly', '17 * * * *', 'select public.dispatch_entitlement_check();');

-- One statement each: a tick or purge that fails records nothing, which
-- job-health reads as the job having stopped. The reminders tick only
-- calls send-reminders for groups with something due, so the tick is what
-- says the schedule is alive.
select cron.unschedule('reminders-home') where exists (select 1 from cron.job where jobname = 'reminders-home');
select cron.schedule(
  'reminders-home', '*/15 * * * *',
  $cmd$insert into public.job_runs (job, ok, detail) select 'reminders-tick', true, jsonb_build_object('fired', public.dispatch_reminders());$cmd$
);

select cron.unschedule('purge-nightly') where exists (select 1 from cron.job where jobname = 'purge-nightly');
select cron.schedule(
  'purge-nightly', '41 3 * * *',
  $cmd$insert into public.job_runs (job, ok, detail) select 'purge-nightly', true, public.purge_old_rows();$cmd$
);

select cron.unschedule('job-health') where exists (select 1 from cron.job where jobname = 'job-health');
select cron.schedule('job-health', '0 8 * * *', 'select public.dispatch_job_health();');
