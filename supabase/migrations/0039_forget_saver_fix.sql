-- 0037 also cleared the old email-keyed members table, which no longer
-- exists (membership is group_members, by user id), so every call failed.
create or replace function public.forget_saver(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(trim(p_email), '') = '' then
    return;
  end if;
  -- The same bypass the membership API uses: this is housekeeping, not an edit.
  perform set_config('cwg.membership', 'on', true);
  update public.items
     set added_by_email = '', updated_at = now(), updated_by = null
   where lower(added_by_email) = lower(trim(p_email));
end;
$$;
