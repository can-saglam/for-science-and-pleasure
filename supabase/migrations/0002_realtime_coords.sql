-- Coordinates for distance-based "nearby" suggestions (geocoded at parse time)
alter table public.items
  add column lat double precision,
  add column lng double precision;

-- Live sync between members' devices
alter publication supabase_realtime add table public.items;
