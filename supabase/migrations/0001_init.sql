-- For Science and Pleasure — initial schema
-- A shared pool of saved events & places for a small fixed set of members.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Members: the only people allowed to use the app (seeded by email).
-- Anyone can complete a magic-link sign-in, but RLS checks membership,
-- so non-members can authenticate yet see and touch nothing.
-- ---------------------------------------------------------------------------
create table public.members (
  email text primary key,
  display_name text,
  created_at timestamptz not null default now()
);

alter table public.members enable row level security;

create or replace function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.members
    where email = (auth.jwt() ->> 'email')
  );
$$;

create policy "members can see members"
  on public.members for select
  to authenticated
  using (public.is_member());

-- Seed: Can. Partner gets added with a one-line insert once we have her email.
insert into public.members (email, display_name)
values ('cansaglam@gmail.com', 'Can');

-- ---------------------------------------------------------------------------
-- Items: the shared library of events and places.
-- ---------------------------------------------------------------------------
create type public.item_kind as enum ('event', 'place');
create type public.item_status as enum ('inbox', 'saved', 'planned', 'done', 'archived');

create table public.items (
  id uuid primary key default gen_random_uuid(),
  kind public.item_kind not null default 'event',
  status public.item_status not null default 'inbox',

  title text not null,
  summary text,
  venue text,
  area text,
  address text,
  category text,
  price text,
  url text,
  booking_url text,
  image_url text,

  starts_on date,
  ends_on date,
  planned_for date,

  notes text,
  source text not null default 'manual', -- 'link' | 'text' | 'image' | 'manual' | 'shortcut'
  raw_input text,

  added_by_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index items_status_idx on public.items (status) where deleted_at is null;
create index items_ends_on_idx on public.items (ends_on) where deleted_at is null;
create index items_planned_for_idx on public.items (planned_for) where deleted_at is null;

alter table public.items enable row level security;

create policy "members read items"
  on public.items for select
  to authenticated
  using (public.is_member());

create policy "members insert items"
  on public.items for insert
  to authenticated
  with check (public.is_member());

create policy "members update items"
  on public.items for update
  to authenticated
  using (public.is_member())
  with check (public.is_member());

create policy "members delete items"
  on public.items for delete
  to authenticated
  using (public.is_member());

-- keep updated_at fresh
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger items_touch_updated_at
  before update on public.items
  for each row execute function public.touch_updated_at();
