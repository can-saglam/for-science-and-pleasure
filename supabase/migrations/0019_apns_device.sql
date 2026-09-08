-- One APNs token per device, and each device says which build it runs.
--
-- Until now the app upserted its token keyed on the token alone, so every
-- simulator install during development left another row behind: 57 rows
-- for two phones by 7 Sep. Each row was a real push. This keys tokens by
-- (user, device): registering replaces whatever that device had before,
-- and while it's there, drops the user's legacy rows that carry no device
-- at all — once a phone is on the new build, its old duplicates are gone.
--
-- `build` is the CFBundleVersion the device registered from. It answers
-- "is everyone on ≥ N yet?" before raising app_config.min_build, which so
-- far had to be asked in person.

alter table public.apns_tokens
  add column if not exists device_id text,
  add column if not exists build integer,
  add column if not exists platform text;  -- 'ios' | 'simulator'

-- Nulls are distinct, so the legacy rows (device_id null) don't collide.
create unique index if not exists apns_tokens_user_device_idx
  on public.apns_tokens (user_id, device_id);

-- updated_at only defaulted on insert; re-registering never refreshed it,
-- so "last seen" was really "first seen".
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists apns_tokens_touch on public.apns_tokens;
create trigger apns_tokens_touch
  before update on public.apns_tokens
  for each row execute function public.touch_updated_at();

-- The registration call. Runs as the caller (RLS: users manage own
-- tokens), so it can only ever touch the caller's rows. Replaces the row
-- for this device, drops any other row that already held this token (a
-- reinstall can change the vendor id while APNs keeps the token), and
-- clears the caller's device-less legacy rows.
create or replace function public.register_apns_token(
  p_token text,
  p_device_id text,
  p_build integer,
  p_platform text default 'ios'
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  if p_token is null or length(p_token) < 32 or p_device_id is null or length(p_device_id) < 8 then
    raise exception 'token and device_id required' using errcode = 'check_violation';
  end if;

  delete from public.apns_tokens
  where user_id = auth.uid()
    and (device_id = p_device_id or token = p_token or device_id is null);

  insert into public.apns_tokens (token, user_id, device_id, build, platform)
  values (p_token, auth.uid(), p_device_id, p_build, coalesce(p_platform, 'ios'));
end;
$$;

revoke execute on function public.register_apns_token(text, text, integer, text) from public, anon;
grant execute on function public.register_apns_token(text, text, integer, text) to authenticated;
