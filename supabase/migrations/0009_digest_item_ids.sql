-- The digest sheet shows cards for the events mentioned in the digest text,
-- so the generator records which saved items it talked about.
alter table public.digests
  add column item_ids uuid[] not null default '{}';
