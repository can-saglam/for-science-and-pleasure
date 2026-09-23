-- Nightly App Store re-verification (verify-entitlements). Reuses the
-- reminders cron secret and derives the function URL from the reminders
-- one, so there is nothing new to provision in Vault.

create or replace function public.dispatch_entitlement_check()
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
    url := replace(reminders_url, '/send-reminders', '/verify-entitlements'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cron_secret),
    body := '{}'::jsonb
  );
end;
$$;

revoke all on function public.dispatch_entitlement_check() from public;
revoke all on function public.dispatch_entitlement_check() from anon;
revoke all on function public.dispatch_entitlement_check() from authenticated;

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job from cron.job where jobname = 'entitlements-nightly';
  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
  perform cron.schedule('entitlements-nightly', '17 3 * * *', 'select public.dispatch_entitlement_check();');
end;
$$;
