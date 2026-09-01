-- Shared weekly digest schedule — one row, visible and editable by both
-- members, so the notification always lands on both phones together.
create table public.digest_schedule (
  id boolean primary key default true check (id),
  day_of_week int not null default 2 check (day_of_week between 1 and 7), -- ISO: Mon=1
  hour int not null default 10 check (hour between 0 and 23),
  minute int not null default 0 check (minute between 0 and 59),
  updated_at timestamptz not null default now()
);

insert into public.digest_schedule default values;

alter table public.digest_schedule enable row level security;

create policy "members read digest schedule"
  on public.digest_schedule for select
  to authenticated
  using (public.is_member());

create policy "members update digest schedule"
  on public.digest_schedule for update
  to authenticated
  using (public.is_member())
  with check (public.is_member());

create trigger digest_schedule_touch_updated_at
  before update on public.digest_schedule
  for each row execute function public.touch_updated_at();

-- The dispatcher no longer hard-codes Tuesday 10:00 London. It runs every
-- 15 minutes and fires within the hour after the scheduled moment; the
-- edge function's digest_runs bookkeeping keeps it to once a week.
create or replace function public.dispatch_weekly_digest()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  sched record;
  london_now timestamp := timezone('Europe/London', now());
  now_minutes int;
  sched_minutes int;
  function_url text;
  cron_secret text;
  request_id bigint;
begin
  select day_of_week, hour, minute into sched
  from public.digest_schedule
  limit 1;
  if sched is null then
    return null;
  end if;

  if extract(isodow from london_now) <> sched.day_of_week then
    return null;
  end if;

  now_minutes := extract(hour from london_now)::int * 60
               + extract(minute from london_now)::int;
  sched_minutes := sched.hour * 60 + sched.minute;
  if now_minutes < sched_minutes or now_minutes > sched_minutes + 59 then
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
    '*/15 * * * *',
    'select public.dispatch_weekly_digest();'
  );
end;
$$;
