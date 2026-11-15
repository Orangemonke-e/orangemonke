-- Monke Icon Maker: profile pictures.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (New projects don't need this: setup.sql already includes it.)

-- Each account can point at one picture in its own folder of the "avatars" storage bucket.
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles drop constraint if exists profiles_avatar_path_check;
alter table public.profiles add constraint profiles_avatar_path_check
  check (avatar_path is null or avatar_path like id::text || '/%');
-- People may change their display name and picture, nothing else.
revoke update on public.profiles from anon, authenticated;
grant update (display_name, avatar_path) on public.profiles to authenticated;

-- Public bucket for profile pictures: PNG/WebP/JPEG only, up to 512 KB each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 524288, array['image/png', 'image/webp', 'image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 524288, allowed_mime_types = array['image/png', 'image/webp', 'image/jpeg'];

drop policy if exists "Upload a picture to your own folder" on storage.objects;
create policy "Upload a picture to your own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned());
drop policy if exists "Delete your own pictures, or any as admin" on storage.objects;
create policy "Delete your own pictures, or any as admin" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- Admins can put someone's picture back to the grey monke.
create or replace function public.admin_clear_avatar(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles set avatar_path = null where id = target;
end $$;
revoke execute on function public.admin_clear_avatar(uuid) from public, anon;
grant execute on function public.admin_clear_avatar(uuid) to authenticated;
