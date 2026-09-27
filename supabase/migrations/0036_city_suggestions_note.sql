-- How the last refresh of a suggestions row went ("kept 6 of 9 in 84s",
-- or the error), so a city stuck with nothing can be diagnosed from the
-- table instead of the function logs.
alter table public.city_suggestions add column if not exists last_note text;
