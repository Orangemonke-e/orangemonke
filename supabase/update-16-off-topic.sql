-- Monke Icon Maker: an Off topic section in the community gallery.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-10 (remix) first. New projects: setup.sql has it all.)
--
-- Icons that aren't Gorilla Tag monkes (like a Roblox noob) go in "Off topic" instead of the main gallery.
-- You choose when you share. The person who shared an icon, or an admin, can move it between the two.

alter table public.posts add column if not exists off_topic boolean not null default false;
create index if not exists posts_topic_created_idx on public.posts (off_topic, created_at desc);
grant insert (image_path, title, design, remix_of, off_topic) on public.posts to authenticated;

-- Move an icon between the main gallery and Off topic. Only the person who shared it, or an admin, can move it.
create or replace function public.set_post_topic(p_post uuid, p_off boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  if auth.uid() is null or public.is_banned() then return false; end if;
  update public.posts set off_topic = coalesce(p_off, false)
   where id = p_post and (user_id = auth.uid() or public.is_admin())
  returning true into ok;
  return coalesce(ok, false);
end $$;
revoke execute on function public.set_post_topic(uuid, boolean) from public, anon;
grant execute on function public.set_post_topic(uuid, boolean) to authenticated;
