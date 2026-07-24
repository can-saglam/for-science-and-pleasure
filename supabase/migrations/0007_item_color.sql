-- Accent colour sampled from the item's source (og:image or screenshot),
-- used to tint cards in the UI. Hex string like '#a34f2b'.
alter table public.items add column if not exists color text;
