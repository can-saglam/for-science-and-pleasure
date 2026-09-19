-- Notify debounce, invite attempt limits, and daily parse/locate/suggest caps.

create table if not exists public.notify_recent (
  group_id uuid not null,
  item_id uuid not null,
  actor uuid not null,
  sent_at timestamptz not null default now(),
  primary key (group_id, item_id, actor)
);

create table if not exists public.invite_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  code text,
  ok boolean not null default false,
  at timestamptz not null default now()
);
create index if not exists invite_attempts_user_at on public.invite_attempts (user_id, at desc);
create index if not exists invite_attempts_code_at on public.invite_attempts (code, at desc);

create table if not exists public.usage_daily (
  user_id uuid not null,
  day date not null,
  parse int not null default 0,
  locate int not null default 0,
  suggest int not null default 0,
  primary key (user_id, day)
);

alter table public.notify_recent enable row level security;
alter table public.invite_attempts enable row level security;
alter table public.usage_daily enable row level security;
