-- 0023: what a code holder may learn, and who may call the helpers.
--
-- membership_preview returned the whole group card — including the group's
-- *other* live invite codes and its id — to anyone holding any code for it,
-- even a revoked or expired one. Cancelling an invite was therefore not a
-- real cancellation: the dead code still read out a live one. The preview
-- now shows only what the join screen needs (status, inviter, name, home,
-- members, headcount), and nothing at all beyond the status for a code
-- that is dead ('revoked', 'expired') or unusable ('own').
--
-- The plus/name helpers were still executable by any signed-in user through
-- PostgREST (rpc/user_is_plus with any uuid told you someone's subscription
-- status). They are only ever called from security-definer functions and
-- triggers that run as the owner, so the client roles lose them.

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
  card jsonb;
begin
  select group_id into own from public.group_members where user_id = p_user;
  select * into inv from public.group_invites where code = upper(replace(p_code, '-', ''));
  st := public.invite_status(inv, own, p_user);
  if st in ('unknown', 'own') then
    return jsonb_build_object('status', st);
  end if;
  if st in ('revoked', 'expired') then
    -- Just enough to say "ask Joyce for a new one".
    return jsonb_build_object('status', st,
      'inviter', (select display_name from public.profiles where user_id = inv.created_by));
  end if;
  card := public.group_card(inv.group_id);
  return jsonb_build_object(
    'status', st,
    'inviter', (select display_name from public.profiles where user_id = inv.created_by),
    'name', card->'name',
    'home_locality', card->'home_locality',
    'capacity', card->'capacity',
    'is_plus', card->'is_plus',
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'display_name', m->'display_name',
        'avatar_colour', m->'avatar_colour'
      )), '[]'::jsonb)
      from jsonb_array_elements(card->'members') m
    )
  );
end;
$$;

revoke execute on function
  public.user_is_plus(uuid),
  public.group_is_plus(uuid),
  public.group_auto_name(uuid)
from public, anon, authenticated;
