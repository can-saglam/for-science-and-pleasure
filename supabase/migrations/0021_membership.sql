-- Phase 2 / 2b — membership foundations (launch plan → "Inviting people",
-- "Two rules for joining and leaving", "My group", "Edge rules").
--
-- Everything that decides who is in which group lives here, in
-- security-definer functions the `group-membership` edge function calls
-- with the service role. Clients never insert into group_members, groups or
-- group_invites directly — the policies below give them read access only.
--
--   provisioning   a new auth user gets a profile, a personal group, a
--                  membership and a default digest schedule (trigger)
--   invites        6-character codes, 7 days, multi-use, revocable
--   join           moves the joiner's saves in (URL dedupe), dissolves the
--                  empty personal group; atomic, row-locked, cap-checked
--   leave          fresh personal group, optional copy of the library,
--                  the group keeps everything; feed token rotates
--   names          groups name themselves from their members until pinned
--   colours        one avatar colour per member, first unused in the group
--   cap            2 free / 4 Plus, enforced at join (trigger as backstop)
--   tombstones     profiles outlive their auth user so attribution never
--                  renders blank

-- ---------------------------------------------------------------------------
-- Invites
-- ---------------------------------------------------------------------------

create table if not exists public.group_invites (
  -- Six characters from an alphabet without 0/O/1/I; shown as ABC-DEF.
  code text primary key check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  group_id uuid not null references public.groups (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  revoked_at timestamptz
);
create index if not exists group_invites_group_idx on public.group_invites (group_id);

alter table public.group_invites enable row level security;
drop policy if exists "members read own group's invites" on public.group_invites;
create policy "members read own group's invites"
  on public.group_invites for select
  to authenticated
  using (group_id = public.current_group_id());

-- ---------------------------------------------------------------------------
-- Groups: pinned names, length limits
-- ---------------------------------------------------------------------------

alter table public.groups
  add column if not exists name_pinned boolean not null default false;
alter table public.groups drop constraint if exists groups_name_len;
alter table public.groups
  add constraint groups_name_len check (char_length(btrim(name)) between 1 and 30);

-- ---------------------------------------------------------------------------
-- Profiles: tombstone-ready, colour, length limit
-- ---------------------------------------------------------------------------

-- A deleted account leaves its profile behind as a "Former member" (name and
-- colour cleared, id kept) so "Added by" and "Edited by" never go blank. That
-- needs the row to survive the auth.users delete — so no cascade, and item
-- attribution stops being a foreign key (it's history, not integrity).
alter table public.profiles drop constraint if exists profiles_user_id_fkey;
alter table public.profiles add column if not exists former_at timestamptz;
alter table public.profiles drop constraint if exists profiles_display_name_len;
alter table public.profiles
  add constraint profiles_display_name_len
  check (display_name is null or char_length(display_name) between 1 and 24);

alter table public.items drop constraint if exists items_created_by_fkey;
alter table public.items drop constraint if exists items_updated_by_fkey;
create index if not exists items_created_by_idx on public.items (created_by);
create index if not exists items_updated_by_idx on public.items (updated_by);

-- Members read the profiles of everyone in the group *and* of anyone who
-- ever saved or edited one of the group's items (former members).
drop policy if exists "members read group profiles" on public.profiles;
create policy "members read group profiles"
  on public.profiles for select
  to authenticated
  using (
    user_id in (
      select user_id from public.group_members
      where group_id = public.current_group_id()
    )
    or exists (
      select 1 from public.items i
      where i.group_id = public.current_group_id()
        and (i.created_by = profiles.user_id or i.updated_by = profiles.user_id)
    )
  );

-- ---------------------------------------------------------------------------
-- Names and colours
-- ---------------------------------------------------------------------------

-- "Can's saves" · "Can & Joyce" · "Can, Joyce & Sam". Members without a name
-- yet read as "Someone" — onboarding insists on a name, so briefly at most.
create or replace function public.group_auto_name(gid uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  with names as (
    select coalesce(nullif(btrim(p.display_name), ''), 'Someone') as n
    from public.group_members m
    left join public.profiles p on p.user_id = m.user_id
    where m.group_id = gid
    order by m.joined_at, m.user_id
  ),
  agg as (
    select array_agg(n) as arr, count(*) as c from names
  )
  select left(
    case
      when c = 0 then 'Saves'
      when c = 1 then arr[1] || '''s saves'
      else array_to_string(arr[1:(c - 1)::int], ', ') || ' & ' || arr[c::int]
    end, 30)
  from agg;
$$;

create or replace function public.refresh_group_name(gid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if gid is null then return; end if;
  update public.groups
  set name = public.group_auto_name(gid)
  where id = gid and not name_pinned;
end;
$$;

create or replace function public.group_members_after_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then perform public.refresh_group_name(new.group_id); end if;
  if tg_op in ('DELETE', 'UPDATE') then perform public.refresh_group_name(old.group_id); end if;
  return null;
end;
$$;
drop trigger if exists group_members_name on public.group_members;
create trigger group_members_name
  after insert or update or delete on public.group_members
  for each row execute function public.group_members_after_change();

create or replace function public.profiles_after_rename()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.display_name is distinct from old.display_name then
    perform public.refresh_group_name((select group_id from public.group_members where user_id = new.user_id));
  end if;
  return null;
end;
$$;
drop trigger if exists profiles_name on public.profiles;
create trigger profiles_name
  after update on public.profiles
  for each row execute function public.profiles_after_rename();

-- Fixed palette; a joiner takes the first colour nobody else in the group
-- has, so two Sams stay tellable apart. Stored as a name the app maps.
create or replace function public.assign_avatar_colour()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  palette text[] := array['coral', 'mint', 'sky', 'lilac', 'amber', 'rose', 'teal', 'plum'];
  taken text[];
  pick text;
  c text;
begin
  select coalesce(array_agg(p.avatar_colour), '{}') into taken
  from public.group_members m
  join public.profiles p on p.user_id = m.user_id
  where m.group_id = new.group_id and m.user_id <> new.user_id and p.avatar_colour is not null;

  foreach c in array palette loop
    if not (c = any(taken)) then pick := c; exit; end if;
  end loop;
  if pick is null then pick := palette[1 + (abs(hashtext(new.user_id::text)) % array_length(palette, 1))]; end if;

  insert into public.profiles (user_id, avatar_colour)
  values (new.user_id, pick)
  on conflict (user_id) do update set avatar_colour = excluded.avatar_colour;
  return null;
end;
$$;
drop trigger if exists group_members_colour on public.group_members;
create trigger group_members_colour
  after insert on public.group_members
  for each row execute function public.assign_avatar_colour();

-- Founders: colours now, and the founding group's name is theirs to keep.
update public.groups set name_pinned = true
where id = (select id from public.groups order by created_at limit 1);
do $$
declare r record;
begin
  for r in select user_id, group_id from public.group_members order by joined_at loop
    if (select avatar_colour from public.profiles where user_id = r.user_id) is null then
      update public.profiles p set avatar_colour = sub.pick
      from (
        select c as pick
        from unnest(array['coral', 'mint', 'sky', 'lilac', 'amber', 'rose', 'teal', 'plum']) with ordinality as u(c, ord)
        where c not in (
          select p2.avatar_colour from public.group_members m2
          join public.profiles p2 on p2.user_id = m2.user_id
          where m2.group_id = r.group_id and p2.avatar_colour is not null
        )
        order by ord limit 1
      ) sub
      where p.user_id = r.user_id;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Cap: 2 free / 4 Plus. The joiner's own Plus counts — a subscriber joining
-- a full free pair is exactly what Plus is for.
-- ---------------------------------------------------------------------------

create or replace function public.user_is_plus(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.entitlements e
    where e.user_id = uid and (e.expires_at is null or e.expires_at > now())
  );
$$;

create or replace function public.enforce_group_cap()
returns trigger
language plpgsql
as $$
declare n int;
begin
  select count(*) into n from public.group_members where group_id = new.group_id;
  if n >= 4 then
    raise exception 'group is full' using errcode = 'check_violation';
  end if;
  if n >= 2 and not (public.group_is_plus(new.group_id) or public.user_is_plus(new.user_id)) then
    raise exception 'group is full for free tier' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Provisioning: every new auth user gets a place to save things
-- ---------------------------------------------------------------------------

create or replace function public.provision_personal_group(uid uuid, p_home_from uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
  src public.groups;
  sched public.digest_schedules;
begin
  insert into public.profiles (user_id) values (uid)
  on conflict (user_id) do nothing;

  -- Home and digest time are inherited from the group being left (if any):
  -- someone leaving "Can & Joyce" still lives in London.
  if p_home_from is not null then
    select * into src from public.groups where id = p_home_from;
    select * into sched from public.digest_schedules where group_id = p_home_from;
  end if;

  insert into public.groups (name, created_by, home_locality, home_country, home_timezone, home_lat, home_lng)
  values ('Saves', uid, src.home_locality, src.home_country, coalesce(src.home_timezone, 'Europe/London'), src.home_lat, src.home_lng)
  returning id into gid;

  insert into public.digest_schedules (group_id, day_of_week, hour, minute, timezone)
  values (gid, coalesce(sched.day_of_week, 4), coalesce(sched.hour, 10), coalesce(sched.minute, 0),
          coalesce(sched.timezone, src.home_timezone, 'Europe/London'));

  insert into public.group_members (user_id, group_id) values (uid, gid);
  return gid;
end;
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.group_members where user_id = new.id) then
    perform public.provision_personal_group(new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- Items guard: let the membership function move rows between groups
-- ---------------------------------------------------------------------------

-- items_touch_and_guard pins group_id on every update — right for clients,
-- wrong for a join that moves a library. The membership functions set
-- cwg.membership = 'on' for their transaction; the guard steps aside and
-- leaves updated_at/updated_by untouched (a move is not an edit).
create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
declare
  machine_only boolean;
  exempt text[] := array['updated_at', 'updated_by', 'created_by', 'group_id', 'image_url', 'color'];
begin
  if current_setting('cwg.membership', true) = 'on' then
    return new;
  end if;

  if new.updated_at is not null
     and old.updated_at is not null
     and new.updated_at < old.updated_at then
    return null; -- stale replay: keep the stored row
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

-- ---------------------------------------------------------------------------
-- The membership API (service role only)
-- ---------------------------------------------------------------------------

-- Scheme, www, fragment and trailing slashes don't make a link a different
-- save (mirrors SavedURLIndex.normalize in the app).
create or replace function public.normalise_url(raw_url text)
returns text
language sql
immutable
as $$
  select nullif(rtrim(regexp_replace(regexp_replace(lower(btrim(s.no_fragment)), '^https?://', ''), '^www\.', ''), '/'), '')
  from (select split_part(coalesce(raw_url, ''), '#', 1) as no_fragment) s;
$$;

create or replace function public.invite_status(inv public.group_invites, gid_of_caller uuid, caller uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare n int;
begin
  if inv.code is null then return 'unknown'; end if;
  if inv.group_id = gid_of_caller then return 'own'; end if;
  if inv.revoked_at is not null then return 'revoked'; end if;
  if inv.expires_at < now() then return 'expired'; end if;
  select count(*) into n from public.group_members where group_id = inv.group_id;
  if n >= 4 then return 'full'; end if;
  if n >= 2 and not (public.group_is_plus(inv.group_id) or public.user_is_plus(caller)) then return 'plus_required'; end if;
  return 'ok';
end;
$$;

create or replace function public.group_card(gid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'group_id', g.id,
    'name', g.name,
    'name_pinned', g.name_pinned,
    'home_locality', g.home_locality,
    'home_country', g.home_country,
    'is_plus', public.group_is_plus(g.id),
    'capacity', case when public.group_is_plus(g.id) then 4 else 2 end,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', m.user_id,
        'display_name', p.display_name,
        'avatar_colour', p.avatar_colour,
        'is_plus', public.user_is_plus(m.user_id),
        'joined_at', m.joined_at
      ) order by m.joined_at)
      from public.group_members m
      left join public.profiles p on p.user_id = m.user_id
      where m.group_id = g.id
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(jsonb_build_object('code', i.code, 'expires_at', i.expires_at) order by i.created_at desc)
      from public.group_invites i
      where i.group_id = g.id and i.revoked_at is null and i.expires_at > now()
    ), '[]'::jsonb)
  )
  from public.groups g where g.id = gid;
$$;

-- invite: a fresh code for the caller's group, or why not.
create or replace function public.membership_invite(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
  n int;
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  new_code text;
  i int;
begin
  select group_id into gid from public.group_members where user_id = p_user;
  if gid is null then return jsonb_build_object('error', 'no_group'); end if;

  select count(*) into n from public.group_members where group_id = gid;
  if n >= 4 then return jsonb_build_object('error', 'full'); end if;
  if n >= 2 and not public.group_is_plus(gid) then return jsonb_build_object('error', 'plus_required'); end if;

  loop
    new_code := '';
    for i in 1..6 loop
      new_code := new_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.group_invites where code = new_code);
  end loop;

  insert into public.group_invites (code, group_id, created_by) values (new_code, gid, p_user);
  return jsonb_build_object('code', new_code, 'expires_at', now() + interval '7 days');
end;
$$;

create or replace function public.membership_revoke(p_user uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare gid uuid; n int;
begin
  select group_id into gid from public.group_members where user_id = p_user;
  update public.group_invites set revoked_at = now()
  where code = upper(replace(p_code, '-', '')) and group_id = gid and revoked_at is null;
  get diagnostics n = row_count;
  return jsonb_build_object('revoked', n > 0);
end;
$$;

-- preview: what a code leads to, before agreeing to anything.
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

-- Moves (or copies) the non-deleted saves of one group into another with URL
-- dedupe: a twin already in the target keeps its row and gains the notes.
create or replace function public.transfer_items(src uuid, dst uuid, copy boolean)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  moved int := 0;
  r record;
  twin uuid;
  twin_notes text;
begin
  perform set_config('cwg.membership', 'on', true);

  for r in select * from public.items where group_id = src and deleted_at is null loop
    twin := null;
    if r.url is not null then
      select id, notes into twin, twin_notes from public.items t
      where t.group_id = dst and t.deleted_at is null
        and public.normalise_url(t.url) = public.normalise_url(r.url)
      order by created_at limit 1;
    end if;

    if twin is not null then
      if r.notes is not null and btrim(r.notes) <> '' and position(r.notes in coalesce(twin_notes, '')) = 0 then
        update public.items set notes = nullif(concat_ws(E'\n\n', nullif(twin_notes, ''), r.notes), '')
        where id = twin;
      end if;
      if not copy then
        -- The group is dissolving; the twin already lives on in the target.
        delete from public.items where id = r.id;
      end if;
    elsif copy then
      insert into public.items (
        kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        raw_input, source, notes, added_by_email, created_by, updated_by, group_id,
        created_at, updated_at
      )
      select kind, status, title, summary, url, booking_url, image_url, color, category,
        venue, address, area, lat, lng, starts_on, ends_on, planned_for, price,
        raw_input, source, notes, added_by_email, created_by, updated_by, dst,
        created_at, updated_at
      from public.items where id = r.id;
      moved := moved + 1;
    else
      update public.items set group_id = dst where id = r.id;
      moved := moved + 1;
    end if;
  end loop;

  if not copy then
    -- Trash and anything else left behind follows the library.
    update public.items set group_id = dst where group_id = src;
  end if;
  return moved;
end;
$$;

-- join: atomic. Locks both groups, re-checks the code and the cap under the
-- lock (two people racing for the last seat: one joins, one sees 'full'),
-- brings the joiner's saves along, dissolves an emptied personal group.
create or replace function public.membership_join(p_user uuid, p_code text, p_keep_copy boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.group_invites;
  old_gid uuid;
  others int;
  st text;
  moved int := 0;
begin
  select group_id into old_gid from public.group_members where user_id = p_user;
  if old_gid is null then return jsonb_build_object('error', 'no_group'); end if;

  select * into inv from public.group_invites where code = upper(replace(p_code, '-', ''));
  if inv.code is null then return jsonb_build_object('error', 'unknown'); end if;

  -- Lock in a fixed order so two cross-joins can't deadlock.
  perform 1 from public.groups where id in (inv.group_id, old_gid) order by id for update;

  st := public.invite_status(inv, old_gid, p_user);
  if st <> 'ok' then return jsonb_build_object('error', st); end if;

  select count(*) - 1 into others from public.group_members where group_id = old_gid;

  perform set_config('cwg.membership', 'on', true);

  if others = 0 then
    -- Solo: the whole library comes along and the empty group goes.
    moved := public.transfer_items(old_gid, inv.group_id, false);
  elsif p_keep_copy then
    -- Leaving a shared group for another: copies come, the group keeps all.
    moved := public.transfer_items(old_gid, inv.group_id, true);
  end if;

  delete from public.group_members where user_id = p_user;
  insert into public.group_members (user_id, group_id) values (p_user, inv.group_id);

  if others = 0 then
    delete from public.groups where id = old_gid;
  else
    update public.groups set feed_token = encode(extensions.gen_random_bytes(16), 'hex') where id = old_gid;
  end if;

  return jsonb_build_object('joined', true, 'moved', moved) || public.group_card(inv.group_id);
end;
$$;

-- leave: a fresh personal group (home and digest time inherited), optionally
-- seeded with a copy of the library. The group keeps everything and gets a
-- new feed token so the old calendar URL stops working for the leaver.
create or replace function public.membership_leave(p_user uuid, p_keep_copy boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  old_gid uuid;
  old_name text;
  new_gid uuid;
  others int;
  copied int := 0;
begin
  select group_id into old_gid from public.group_members where user_id = p_user;
  if old_gid is null then return jsonb_build_object('error', 'no_group'); end if;

  perform 1 from public.groups where id = old_gid for update;
  select count(*) - 1 into others from public.group_members where group_id = old_gid;
  if others = 0 then
    return jsonb_build_object('error', 'already_solo') || public.group_card(old_gid);
  end if;
  -- The name as the leaver knew it, for "You've left Can & Joyce".
  select name into old_name from public.groups where id = old_gid;

  perform set_config('cwg.membership', 'on', true);

  delete from public.group_members where user_id = p_user;
  new_gid := public.provision_personal_group(p_user, old_gid);
  if p_keep_copy then
    copied := public.transfer_items(old_gid, new_gid, true);
  end if;
  update public.groups set feed_token = encode(extensions.gen_random_bytes(16), 'hex') where id = old_gid;

  return jsonb_build_object('left', true, 'copied', copied, 'former_group_name', old_name)
    || public.group_card(new_gid);
end;
$$;

-- rename: pins the name. Empty → back to auto-naming.
create or replace function public.membership_rename(p_user uuid, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare gid uuid; clean text;
begin
  select group_id into gid from public.group_members where user_id = p_user;
  if gid is null then return jsonb_build_object('error', 'no_group'); end if;
  clean := left(btrim(coalesce(p_name, '')), 30);
  if clean = '' then
    update public.groups set name_pinned = false where id = gid;
    perform public.refresh_group_name(gid);
  else
    update public.groups set name = clean, name_pinned = true where id = gid;
  end if;
  return public.group_card(gid);
end;
$$;

-- The card the app shows at the top of Settings.
create or replace function public.membership_card(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.group_card(group_id) from public.group_members where user_id = p_user;
$$;

revoke execute on function
  public.membership_invite(uuid),
  public.membership_revoke(uuid, text),
  public.membership_preview(uuid, text),
  public.membership_join(uuid, text, boolean),
  public.membership_leave(uuid, boolean),
  public.membership_rename(uuid, text),
  public.membership_card(uuid),
  public.transfer_items(uuid, uuid, boolean),
  public.provision_personal_group(uuid, uuid),
  public.group_card(uuid),
  public.invite_status(public.group_invites, uuid, uuid),
  public.refresh_group_name(uuid)
from public, anon, authenticated;
