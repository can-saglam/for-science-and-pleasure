-- Rollback for 0023_preview_privacy.sql: restore the 0021 preview (full
-- card) and the default execute grants on the helpers.

create or replace function public.membership_preview(p_user uuid, p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  inv public.group_invites;
  own uuid;
  st text;
begin
  select group_id into own from public.group_members where user_id = p_user;
  select * into inv from public.group_invites where code = upper(replace(p_code, '-', ''));
  st := public.invite_status(inv, own, p_user);
  if st = 'unknown' then return jsonb_build_object('status', st); end if;
  return jsonb_build_object('status', st, 'inviter', (select display_name from public.profiles where user_id = inv.created_by))
    || public.group_card(inv.group_id);
end;
$$;

grant execute on function
  public.user_is_plus(uuid),
  public.group_is_plus(uuid),
  public.group_auto_name(uuid)
to authenticated;

delete from supabase_migrations.schema_migrations where version = '0023';
