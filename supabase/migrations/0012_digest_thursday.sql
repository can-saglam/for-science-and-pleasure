-- The digest now previews the weekend (Fri–Sun), so it lands Thursday
-- morning by default instead of Tuesday.

alter table public.digest_schedule
  alter column day_of_week set default 4;

update public.digest_schedule
set day_of_week = 4, updated_at = now()
where id = true and day_of_week = 2;
