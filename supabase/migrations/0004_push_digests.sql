-- Persist weekly digests and deliver them through Web Push.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

create table public.digests (
  id uuid primary key default gen_random_uuid(),
  week_start date not null unique,
  text text not null,
  created_at timestamptz not null default now()
);

alter table public.digests enable row level security;

create policy "members read digests"
  on public.digests for select
  to authenticated
  using (public.is_member());

create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.push_subscriptions enable row level security;

create policy "members read own push subscriptions"
  on public.push_subscriptions for select
  to authenticated
  using (public.is_member() and user_id = auth.uid());

create policy "members insert own push subscriptions"
  on public.push_subscriptions for insert
  to authenticated
  with check (public.is_member() and user_id = auth.uid());

create policy "members update own push subscriptions"
  on public.push_subscriptions for update
  to authenticated
  using (public.is_member() and user_id = auth.uid())
  with check (public.is_member() and user_id = auth.uid());

create policy "members delete own push subscriptions"
  on public.push_subscriptions for delete
  to authenticated
  using (public.is_member() and user_id = auth.uid());

create trigger push_subscriptions_touch_updated_at
  before update on public.push_subscriptions
  for each row execute function public.touch_updated_at();

create table public.digest_runs (
  week_start date primary key,
  status text not null check (status in ('running', 'completed', 'failed')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  error text
);

alter table public.digest_runs enable row level security;

-- Called by pg_cron at both possible UTC equivalents of 10:00 Europe/London.
-- Secret values are provisioned into Vault during deployment, never committed.
create or replace function public.dispatch_weekly_digest()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  london_now timestamp := timezone('Europe/London', now());
  function_url text;
  cron_secret text;
  request_id bigint;
begin
  if extract(isodow from london_now) <> 2 or extract(hour from london_now) <> 10 then
    return null;
  end if;

  select decrypted_secret
  into function_url
  from vault.decrypted_secrets
  where name = 'weekly_digest_url'
  limit 1;

  select decrypted_secret
  into cron_secret
  from vault.decrypted_secrets
  where name = 'weekly_digest_cron_secret'
  limit 1;

  if function_url is null or cron_secret is null then
    raise warning 'Weekly digest Vault secrets have not been provisioned';
    return null;
  end if;

  select net.http_post(
    url := function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', cron_secret
    ),
    body := jsonb_build_object('scheduled_for', london_now::date)
  )
  into request_id;

  return request_id;
end;
$$;

revoke all on function public.dispatch_weekly_digest() from public;
revoke all on function public.dispatch_weekly_digest() from anon;
revoke all on function public.dispatch_weekly_digest() from authenticated;

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname = 'weekly-digest-london';

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;

  perform cron.schedule(
    'weekly-digest-london',
    '0 9,10 * * 2',
    'select public.dispatch_weekly_digest();'
  );
end;
$$;
