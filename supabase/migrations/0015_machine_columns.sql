-- Machine-derived columns don't count as edits (launch plan, Phase 0).
--
-- image_url and color are filled in by backfills and the parser, not by
-- people. Until now any such write bumped updated_at like a real edit, which
-- had two bad effects: it made the row look freshly touched by a person, and
-- — worse — it advanced the stale-write guard's clock, so a partner's
-- genuine edit made offline moments earlier would be rejected as a replay
-- when their phone came back.
--
-- Now an UPDATE that changes nothing except those columns keeps the row's
-- updated_at exactly as it was. Every phone derives its own thumbnail the
-- same way, so nothing needs to propagate through the timestamp. Any change
-- to any other column still stamps now() as before.
--
-- The comparison is done on the rows as JSON minus the exempt columns, so
-- adding columns later doesn't silently break it.

create or replace function public.items_touch_and_guard()
returns trigger
language plpgsql
as $$
declare
  machine_only boolean;
begin
  -- Stale replay (an old client writing a whole row it holds from weeks
  -- ago): drop it, keep the stored row.
  if new.updated_at is not null
     and old.updated_at is not null
     and new.updated_at < old.updated_at then
    return null;
  end if;

  machine_only :=
    (to_jsonb(new) - 'updated_at' - 'image_url' - 'color')
    = (to_jsonb(old) - 'updated_at' - 'image_url' - 'color');

  if machine_only then
    new.updated_at = old.updated_at;
  else
    new.updated_at = now();
  end if;
  return new;
end;
$$;
