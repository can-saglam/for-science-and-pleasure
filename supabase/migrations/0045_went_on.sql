-- When a save was marked done ("We did go"), for the journal's "Went
-- 10 Sep" and the year's tally: a day on the home calendar, set when it's
-- marked done and cleared when it's put back. An ordinary edit, so the
-- touch trigger needs nothing new.
--
-- Saves marked done before this column, or by builds before 109, have
-- none; the app falls back to the planned day, then the last edit.
-- Clients that don't know the column leave it out of their upserts, so
-- the date survives their writes.

alter table public.items add column if not exists went_on date;
