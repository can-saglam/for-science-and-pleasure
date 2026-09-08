-- The Shortcut ingest path identifies its caller by the email baked into the
-- Shortcut. Account emails can now change (Can's moved to his Apple Account
-- address for Sign in with Apple), so fall back to the address's history:
-- a user who has saved items under that email is that email's owner.
create or replace function public.group_for_email(p_email text)
returns table (group_id uuid, user_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select gm.group_id, gm.user_id
  from auth.users u
  join public.group_members gm on gm.user_id = u.id
  where lower(u.email) = lower(p_email)
  union all
  select gm.group_id, gm.user_id
  from public.items i
  join public.group_members gm on gm.user_id = i.created_by
  where lower(i.added_by_email) = lower(p_email)
    and not exists (select 1 from auth.users u where lower(u.email) = lower(p_email))
  order by 1
  limit 1;
$$;
revoke execute on function public.group_for_email(text) from public, anon, authenticated;
