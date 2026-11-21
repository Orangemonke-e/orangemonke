-- Monke Icon Maker: making-of videos on gallery icons (🎥 Record a video of making your icon → 📤 Post it).
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-16 (off topic) first. New projects: setup.sql has it all.)
--
-- A shared icon can have one video, kept in the new "videos" bucket in the sharer's own folder.
-- Videos are made by the site itself (only the icon, captions and, if you choose, your voice).

alter table public.posts add column if not exists video_path text;
alter table public.posts drop constraint if exists posts_video_path_check;
alter table public.posts add constraint posts_video_path_check check (
  video_path is null or video_path ~ ('^' || user_id::text || '/[a-z0-9]{1,20}\.(mp4|webm)$'));
grant insert (image_path, title, design, remix_of, off_topic, video_path) on public.posts to authenticated;

-- Public bucket for the videos: MP4/WebM only, up to 20 MB each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', true, 20971520, array['video/mp4', 'video/webm'])
on conflict (id) do update set public = true, file_size_limit = 20971520, allowed_mime_types = array['video/mp4', 'video/webm'];

drop policy if exists "Upload videos to your own folder" on storage.objects;
create policy "Upload videos to your own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned());
drop policy if exists "Delete your own videos, or any as admin" on storage.objects;
create policy "Delete your own videos, or any as admin" on storage.objects for delete to authenticated
  using (bucket_id = 'videos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
