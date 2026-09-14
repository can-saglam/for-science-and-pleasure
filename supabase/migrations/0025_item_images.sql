-- User-picked covers for a save. Public read so ImageStore can fetch the
-- same way it fetches an og:image; writes are scoped to the caller's group
-- so one library cannot overwrite another's files.
--
-- Object key: {group_id}/{uuid}.jpg — the group folder is what RLS checks.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'item-images',
  'item-images',
  true,
  3500000,
  array['image/jpeg']
)
on conflict (id) do nothing;

drop policy if exists "anyone can read item images" on storage.objects;
create policy "anyone can read item images"
on storage.objects for select
using (bucket_id = 'item-images');

drop policy if exists "members insert item images" on storage.objects;
create policy "members insert item images"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'item-images'
  and (storage.foldername(name))[1] = public.current_group_id()::text
);

drop policy if exists "members update item images" on storage.objects;
create policy "members update item images"
on storage.objects for update
to authenticated
using (
  bucket_id = 'item-images'
  and (storage.foldername(name))[1] = public.current_group_id()::text
)
with check (
  bucket_id = 'item-images'
  and (storage.foldername(name))[1] = public.current_group_id()::text
);

drop policy if exists "members delete item images" on storage.objects;
create policy "members delete item images"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'item-images'
  and (storage.foldername(name))[1] = public.current_group_id()::text
);
