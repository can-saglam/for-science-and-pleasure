-- Fixes from the October health check.
--
--   reserve_usage / release_usage  the daily AI allowance is taken before a
--     call, in one statement, so parallel requests can't all slip under
--     the cap; a call that isn't charged gives its slot back.
--   membership_invite              codes from a secure random source.
--   public_lookups                 failed invite lookups on the public page,
--     by hashed address, so codes can't be walked without signing in.
--   shared_saves                   a shared card goes when its save is
--     deleted or its sender leaves the library.
--   items                          policies the planner can index, and an
--     index for the app's pull.
--   place_photo_cache              a photo link replayed over and over
--     costs one Google lookup an hour.

create or replace function public.reserve_usage(
  p_user_id uuid,
  p_day date,
  p_kind text,
  p_cap integer,
  p_kind_cap integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind not in ('parse', 'locate', 'suggest') then
    raise exception 'unknown kind %', p_kind using errcode = 'check_violation';
  end if;
  insert into public.usage_daily (user_id, day) values (p_user_id, p_day)
  on conflict (user_id, day) do nothing;
  -- The row lock makes a concurrent reservation re-read the counts.
  update public.usage_daily u set
    parse = u.parse + (p_kind = 'parse')::int,
    locate = u.locate + (p_kind = 'locate')::int,
    suggest = u.suggest + (p_kind = 'suggest')::int
  where u.user_id = p_user_id and u.day = p_day
    and u.parse + u.locate + u.suggest < p_cap
    and (p_kind_cap is null or case p_kind
      when 'parse' then u.parse when 'locate' then u.locate else u.suggest end < p_kind_cap);
  return found;
end;
$$;
revoke execute on function public.reserve_usage(uuid, date, text, integer, integer) from public, anon, authenticated;

create or replace function public.release_usage(p_user_id uuid, p_day date, p_kind text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.usage_daily u set
    parse = greatest(u.parse - (p_kind = 'parse')::int, 0),
    locate = greatest(u.locate - (p_kind = 'locate')::int, 0),
    suggest = greatest(u.suggest - (p_kind = 'suggest')::int, 0)
  where u.user_id = p_user_id and u.day = p_day;
$$;
revoke execute on function public.release_usage(uuid, date, text) from public, anon, authenticated;

create or replace function public.membership_invite(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  gid uuid;
  n int;
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  new_code text;
  bytes bytea;
  i int;
begin
  select group_id into gid from public.group_members where user_id = p_user;
  if gid is null then return jsonb_build_object('error', 'no_group'); end if;

  select count(*) into n from public.group_members where group_id = gid;
  if n >= 4 then return jsonb_build_object('error', 'full'); end if;
  if n >= 2 and not public.group_is_plus(gid) then return jsonb_build_object('error', 'plus_required'); end if;

  loop
    -- 32 letters divide 256, so each byte picks one without bias.
    bytes := gen_random_bytes(6);
    new_code := '';
    for i in 0..5 loop
      new_code := new_code || substr(alphabet, 1 + get_byte(bytes, i) % 32, 1);
    end loop;
    exit when not exists (select 1 from public.group_invites where code = new_code);
  end loop;

  insert into public.group_invites (code, group_id, created_by) values (new_code, gid, p_user);
  return jsonb_build_object('code', new_code, 'expires_at', now() + interval '7 days');
end;
$$;

create table if not exists public.public_lookups (
  id bigint generated always as identity primary key,
  who text not null,                 -- sha-256 of the caller's address
  at timestamptz not null default now()
);
create index if not exists public_lookups_who_at on public.public_lookups (who, at desc);
alter table public.public_lookups enable row level security;
revoke all on public.public_lookups from anon, authenticated;

create index if not exists shared_saves_item on public.shared_saves (item_id);

create or replace function public.unshare_deleted_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' or (new.deleted_at is not null and old.deleted_at is null) then
    delete from public.shared_saves where item_id = old.id;
  end if;
  return null;
end;
$$;

drop trigger if exists items_unshare on public.items;
create trigger items_unshare
  after update of deleted_at or delete on public.items
  for each row execute function public.unshare_deleted_item();

create or replace function public.unshare_on_leave()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.shared_saves s
  using public.items i
  where s.created_by = old.user_id and i.id = s.item_id and i.group_id = old.group_id;
  return null;
end;
$$;

drop trigger if exists group_members_unshare on public.group_members;
create trigger group_members_unshare
  after delete on public.group_members
  for each row execute function public.unshare_on_leave();

-- (select …) runs once per query instead of once per row, so these can
-- use the index below.
drop policy "group reads its items" on public.items;
drop policy "group updates its items" on public.items;
drop policy "group deletes its items" on public.items;

create policy "group reads its items"
  on public.items for select
  to authenticated
  using (group_id = (select public.current_group_id()));

create policy "group updates its items"
  on public.items for update
  to authenticated
  using (group_id = (select public.current_group_id()))
  with check (group_id = (select public.current_group_id()));

create policy "group deletes its items"
  on public.items for delete
  to authenticated
  using (group_id = (select public.current_group_id()));

create index if not exists items_group_updated on public.items (group_id, updated_at);

-- place-photo's answer per place for an hour (null: the place has none).
create table if not exists public.place_photo_cache (
  place_id text primary key,
  uri text,
  fetched_at timestamptz not null default now()
);
alter table public.place_photo_cache enable row level security;
revoke all on public.place_photo_cache from anon, authenticated;
