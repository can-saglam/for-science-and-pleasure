-- Revert of 0021_membership.sql — back to the post-0020 state.
--
-- Not a migration: run by hand (`supabase db push`-style via the Management
-- API, or `supabase db query --linked -f`) if the membership layer has to
-- come down. Rehearsed on staging before 0021 went up.
--
-- What comes back:  the flat 4-member cap, the group_id-pinning items guard
--                   without the membership bypass, the profiles read policy
--                   scoped to current members only, the FKs from profiles
--                   and item attribution to auth.users (only if every
--                   referenced user still exists — see below).
-- What goes:        group_invites, the membership_* API, auto-naming and
--                   colour triggers, the new-user provisioning trigger.
-- What stays:       groups.name_pinned, profiles.avatar_colour values,
--                   profiles.former_at, the two attribution indexes —
--                   harmless to a build-45 client. Personal groups created
--                   for users who signed up in between are left in place;
--                   nothing is deleted by this script.

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_auth_user();

drop trigger if exists group_members_name on public.group_members;
drop trigger if exists group_members_colour on public.group_members;
drop trigger if exists profiles_name on public.profiles;
drop function if exists public.group_members_after_change();
drop function if exists public.profiles_after_rename();
drop function if exists public.assign_avatar_colour();

drop function if exists public.membership_invite(uuid);
drop function if exists public.membership_revoke(uuid, text);
drop function if exists public.membership_preview(uuid, text);
drop function if exists public.membership_join(uuid, text, boolean);
drop function if exists public.membership_leave(uuid, boolean);
drop function if exists public.membership_rename(uuid, text);
drop function if exists public.membership_card(uuid);
drop function if exists public.transfer_items(uuid, uuid, boolean);
drop function if exists public.provision_personal_group(uuid, uuid);
drop function if exists public.group_card(uuid);
drop function if exists public.invite_status(public.group_invites, uuid, uuid);
drop function if exists public.refresh_group_name(uuid);
drop function if exists public.group_auto_name(uuid);
drop function if exists public.user_is_plus(uuid);
drop function if exists public.normalise_url(text);

drop table if exists public.group_invites;

alter table public.groups drop constraint if exists groups_name_len;
alter table public.profiles drop constraint if exists profiles_display_name_len;

-- Flat cap of 4, as 0017 had it.
create or replace function public.enforce_group_cap()
returns trigger
language plpgsql
as $$
declare n int;
begin
  select count(*) into n from public.group_members where group_id = new.group_id;
  if n >= 4 then
    raise exception 'group is full (4 members)' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- Items guard without the membership bypass (0017's version).
create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
declare
  machine_only boolean;
  exempt text[] := array['updated_at', 'updated_by', 'created_by', 'group_id', 'image_url', 'color'];
begin
  if new.updated_at is not null
     and old.updated_at is not null
     and new.updated_at < old.updated_at then
    return null;
  end if;

  new.group_id = old.group_id;
  new.created_by = old.created_by;

  machine_only :=
    (to_jsonb(new) - exempt) = (to_jsonb(old) - exempt);

  if machine_only then
    new.updated_at = old.updated_at;
    new.updated_by = old.updated_by;
  else
    new.updated_at = now();
    new.updated_by = coalesce(auth.uid(), old.updated_by);
  end if;
  return new;
end;
$$;

-- Profiles readable for current members only (0016's policy).
drop policy if exists "members read group profiles" on public.profiles;
create policy "members read group profiles"
  on public.profiles for select
  to authenticated
  using (
    user_id in (
      select user_id from public.group_members
      where group_id = public.current_group_id()
    )
  );

-- The FKs return only when nothing dangles; a tombstone or an item whose
-- author has since been deleted would make them fail, and in that case the
-- history matters more than the constraint.
do $$
begin
  if not exists (select 1 from public.profiles p where not exists (select 1 from auth.users u where u.id = p.user_id)) then
    alter table public.profiles
      add constraint profiles_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade;
  end if;
  if not exists (select 1 from public.items i where i.created_by is not null and not exists (select 1 from auth.users u where u.id = i.created_by)) then
    alter table public.items
      add constraint items_created_by_fkey foreign key (created_by) references auth.users (id) on delete set null;
  end if;
  if not exists (select 1 from public.items i where i.updated_by is not null and not exists (select 1 from auth.users u where u.id = i.updated_by)) then
    alter table public.items
      add constraint items_updated_by_fkey foreign key (updated_by) references auth.users (id) on delete set null;
  end if;
end $$;

-- Forget that 0021 ran, so `supabase db push` would offer it again.
delete from supabase_migrations.schema_migrations where version = '0021';
