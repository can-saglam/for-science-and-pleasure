-- Account deletion takes the person's email off every save they made. The
-- save stays for the library; "Added by" goes quiet. Blank, not null: the
-- app fills a missing address with the current user's own when it pushes
-- a row, which would re-attribute the save to whoever edits it next.
-- updated_at moves so every phone pulls the change; updated_by clears so
-- nobody reads as having just edited it. Service role only.
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
  delete from public.members where lower(email) = lower(trim(p_email));
end;
$$;

revoke execute on function public.forget_saver(text) from public, anon, authenticated;
grant execute on function public.forget_saver(text) to service_role;
