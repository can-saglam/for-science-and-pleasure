-- Free groups: at most four active saves per category.
--
-- Active = not done, not deleted, not ended (ends_on before today in the
-- group's home timezone). Done, missed and deleted saves never count, and
-- neither do saves without a category.
--
-- The trigger judges transitions, not rows: it only refuses a row that is
-- *becoming* active in a category (a new save, a put-back, an undelete, or a
-- move into another category). A routine upsert of a row that was already
-- active passes, so libraries already over the cap keep syncing.
--
-- PostgREST's merge-duplicates upsert fires BEFORE INSERT for the proposed
-- row and then BEFORE UPDATE for the merge. The insert pass stands aside
-- when the id already exists and lets the update pass decide.
--
-- Only client writes are judged: requests whose role is `authenticated` or
-- `anon`. The membership, review-reset and other server functions run as
-- the service role, and may also set `app.bypass_cap` for the transaction;
-- nothing a client sends can do either. The function itself is security
-- definer because group_is_plus is not executable by clients (0023), so
-- the caller is read from the `role` setting, not current_user.
--
-- Named so it runs after items_default_group (fills group_id) and
-- items_touch_updated_at (drops stale replays): row triggers fire in name
-- order.

create or replace function public.item_counts_toward_cap(
  p_status public.item_status, p_deleted_at timestamptz, p_ends_on date, p_today date
)
returns boolean
language sql
immutable
as $$
  select p_status <> 'done' and p_deleted_at is null and (p_ends_on is null or p_ends_on >= p_today);
$$;

create or replace function public.category_key(p_category text)
returns text
language sql
immutable
as $$
  select lower(btrim(coalesce(p_category, '')));
$$;

create or replace function public.enforce_category_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  tz text;
  today date;
  key text := public.category_key(new.category);
  n int;
begin
  if coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
     or coalesce(current_setting('app.bypass_cap', true), '') = 'on'
     or new.group_id is null
     or key = '' then
    return new;
  end if;

  if tg_op = 'INSERT' and exists (select 1 from public.items where id = new.id) then
    return new;
  end if;

  select coalesce(g.home_timezone, 'Europe/London') into tz from public.groups g where g.id = new.group_id;
  today := (now() at time zone coalesce(tz, 'Europe/London'))::date;

  if not public.item_counts_toward_cap(new.status, new.deleted_at, new.ends_on, today) then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and old.group_id is not distinct from new.group_id
     and public.category_key(old.category) = key
     and public.item_counts_toward_cap(old.status, old.deleted_at, old.ends_on, today) then
    return new;
  end if;

  if public.group_is_plus(new.group_id) then
    return new;
  end if;

  -- Two members saving into the same category at once: one wins the fourth
  -- slot, the other is refused.
  perform pg_advisory_xact_lock(hashtext('category_cap|' || new.group_id::text || '|' || key));

  select count(*) into n
  from public.items i
  where i.group_id = new.group_id
    and i.id <> new.id
    and public.category_key(i.category) = key
    and public.item_counts_toward_cap(i.status, i.deleted_at, i.ends_on, today);

  if n >= 4 then
    raise exception 'category_full'
      using errcode = 'P0001', detail = key, hint = 'plus_required';
  end if;
  return new;
end;
$$;

drop trigger if exists items_zz_category_cap on public.items;
create trigger items_zz_category_cap
  before insert or update on public.items
  for each row execute function public.enforce_category_cap();

-- What record-entitlement learns from a verified App Store transaction.
alter table public.entitlements
  add column if not exists product_id text,
  add column if not exists environment text check (environment in ('Production', 'Sandbox', 'Xcode')),
  add column if not exists revoked_at timestamptz;

create unique index if not exists entitlements_original_transaction_idx
  on public.entitlements (original_transaction_id)
  where original_transaction_id is not null;

-- One App Store subscription covers one person: re-posting the same
-- original transaction from a second account must not grant it twice.
comment on index public.entitlements_original_transaction_idx is
  'An App Store subscription belongs to the account that first recorded it.';
