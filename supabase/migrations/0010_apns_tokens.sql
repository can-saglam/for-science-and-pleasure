-- Native iOS push: one row per device token, owned by a member email.
-- The app upserts its APNs token after sign-in; notify-save fans out to
-- every token that isn't the saver's.

create table public.apns_tokens (
  token text primary key,
  email text not null,
  updated_at timestamptz not null default now()
);

alter table public.apns_tokens enable row level security;

create policy "members read apns tokens"
  on public.apns_tokens for select
  to authenticated
  using (public.is_member());

create policy "members insert apns tokens"
  on public.apns_tokens for insert
  to authenticated
  with check (public.is_member());

create policy "members update apns tokens"
  on public.apns_tokens for update
  to authenticated
  using (public.is_member())
  with check (public.is_member());

create policy "members delete apns tokens"
  on public.apns_tokens for delete
  to authenticated
  using (public.is_member());
