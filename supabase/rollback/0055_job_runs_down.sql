-- Undo 0055: the nightly entitlement pass and plain purge come back; the
-- run log, the morning check and MetricKit reports go.

select cron.unschedule('job-health') where exists (select 1 from cron.job where jobname = 'job-health');
drop function if exists public.dispatch_job_health();

select cron.unschedule('reminders-home') where exists (select 1 from cron.job where jobname = 'reminders-home');
select cron.schedule('reminders-home', '*/15 * * * *', 'select public.dispatch_reminders();');

select cron.unschedule('purge-nightly') where exists (select 1 from cron.job where jobname = 'purge-nightly');
select cron.schedule('purge-nightly', '41 3 * * *', 'select public.purge_old_rows();');

select cron.unschedule('entitlements-hourly') where exists (select 1 from cron.job where jobname = 'entitlements-hourly');
select cron.schedule('entitlements-nightly', '17 3 * * *', 'select public.dispatch_entitlement_check();');

drop table if exists public.metric_reports;
drop index if exists public.entitlements_app_store_checked;
alter table public.entitlements drop column if exists checked_at;
drop table if exists public.job_runs;
