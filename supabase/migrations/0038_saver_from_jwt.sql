-- Who saved something comes from the login, not the payload: a member
-- can't file a save under their partner's name or address. Service-role
-- writes (auth.uid() null: the membership API, seeding) keep what they send.
create or replace function public.items_default_group()
returns trigger
language plpgsql
as $$
begin
  if new.group_id is null then
    new.group_id = public.current_group_id();
  end if;
  if auth.uid() is not null then
    new.created_by = auth.uid();
    new.updated_by = auth.uid();
    new.added_by_email = coalesce(nullif(auth.jwt() ->> 'email', ''), new.added_by_email);
  end if;
  return new;
end;
$$;

-- As 0021, with added_by_email joining the columns a row push can't
-- change. An upsert's insert half has just stamped the pusher's address
-- onto the proposed row; this keeps the stored saver.
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
  new.added_by_email = old.added_by_email;

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
