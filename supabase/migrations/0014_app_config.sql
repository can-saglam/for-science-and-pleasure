-- Kill switch (launch plan, Phase 0).
--
-- One row the app reads at the top of every sync. A client whose build
-- number is below min_build shows a full-screen "update" and stops syncing
-- entirely — the direct answer to the retired web PWA coming back after
-- weeks and replaying stale rows over everyone's data. Raising min_build is
-- a one-column edit in the dashboard; no release needed.
--
-- store_url is where the update button sends people: TestFlight today, the
-- App Store listing once there is one. Also a server-side edit, so the
-- switch from beta to store never needs a client change.
--
-- Signed-in users can read it; nothing but the service role can write it.

create table public.app_config (
  id boolean primary key default true check (id),
  min_build int not null default 0,
  store_url text not null default 'itms-beta://',
  updated_at timestamptz not null default now()
);

insert into public.app_config default values;

alter table public.app_config enable row level security;

-- Deliberately not is_member(): every future signed-in user needs this,
-- and it contains nothing sensitive.
create policy "signed-in users read app config"
  on public.app_config for select
  to authenticated
  using (true);

create trigger app_config_touch_updated_at
  before update on public.app_config
  for each row execute function public.touch_updated_at();
