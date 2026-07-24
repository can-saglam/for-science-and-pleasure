-- One-time deployment helper. Only Edge Functions using the service role can
-- copy the cron secret into Vault; clients cannot execute this function.
create or replace function public.provision_weekly_digest_cron(
  p_function_url text,
  p_cron_secret text
)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required';
  end if;

  delete from vault.secrets
  where name in ('weekly_digest_url', 'weekly_digest_cron_secret');

  perform vault.create_secret(
    p_function_url,
    'weekly_digest_url',
    'Can We Go weekly digest Edge Function URL'
  );
  perform vault.create_secret(
    p_cron_secret,
    'weekly_digest_cron_secret',
    'Can We Go weekly digest cron authentication'
  );
end;
$$;

revoke all on function public.provision_weekly_digest_cron(text, text) from public;
revoke all on function public.provision_weekly_digest_cron(text, text) from anon;
revoke all on function public.provision_weekly_digest_cron(text, text) from authenticated;
grant execute on function public.provision_weekly_digest_cron(text, text) to service_role;
