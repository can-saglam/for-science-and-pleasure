-- A simulator registering must not sweep the account's legacy rows: that
-- would silently drop the *phone's* pre-0019 token every time a dev build
-- runs, leaving the phone without partner pushes until it next launches.
-- Simulators only ever replace their own device row.

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
    and (
      device_id = p_device_id
      or token = p_token
      or (device_id is null and coalesce(p_platform, 'ios') <> 'simulator')
    );

  insert into public.apns_tokens (token, user_id, device_id, build, platform)
  values (p_token, auth.uid(), p_device_id, p_build, coalesce(p_platform, 'ios'));
end;
$$;
