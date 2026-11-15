-- Monke Icon Maker: community gallery setup for Supabase.
-- Run this once in your Supabase project: Dashboard > SQL Editor > New query > paste all of this > Run.
-- It is safe to run again; it won't delete anything.

-- ───────────────────────── Profiles ─────────────────────────
-- One row per account. Usernames are unique (ignoring capital letters) and can't be changed.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 30),
  avatar_url text,                       -- empty means the default grey monke
  is_admin boolean not null default false,
  banned boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_username_key on public.profiles (lower(username));

-- Makes the profile when someone signs up, from the username and display name they typed.
-- If the username is already taken, the whole sign-up is cancelled.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, display_name)
  values (new.id,
          lower(new.raw_user_meta_data->>'username'),
          btrim(coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username')));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Lets the sign-up form say "that username is taken" before you submit.
create or replace function public.username_available(name text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.profiles where lower(username) = lower(name));
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select banned from public.profiles where id = auth.uid()), false);
$$;

alter table public.profiles enable row level security;
grant select on public.profiles to anon, authenticated;
drop policy if exists "Profiles are public" on public.profiles;
create policy "Profiles are public" on public.profiles for select using (true);
drop policy if exists "Edit your own profile" on public.profiles;
create policy "Edit your own profile" on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
-- People may only change their display name (not their username, admin or banned flags).
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (display_name) on public.profiles to authenticated;

-- ───────────────────────── Posts ─────────────────────────
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  image_path text not null,              -- file in the "icons" storage bucket
  title text check (title is null or char_length(title) <= 40),
  report_count int not null default 0,
  hidden boolean not null default false, -- hidden automatically after 3 reports
  created_at timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);

alter table public.posts enable row level security;
drop policy if exists "See visible posts" on public.posts;
create policy "See visible posts" on public.posts for select using (
  (not hidden and not exists (select 1 from public.profiles p where p.id = posts.user_id and p.banned))
  or user_id = auth.uid() or public.is_admin());
drop policy if exists "Share your own icons" on public.posts;
create policy "Share your own icons" on public.posts for insert to authenticated with check (
  user_id = auth.uid() and not public.is_banned()
  and image_path like auth.uid()::text || '/%');
drop policy if exists "Delete your own posts, or any as admin" on public.posts;
create policy "Delete your own posts, or any as admin" on public.posts for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.posts from anon, authenticated;
grant select on public.posts to anon, authenticated;
grant insert (image_path, title) on public.posts to authenticated;
grant delete on public.posts to authenticated;

-- Spam guard: at most 20 shares per account per day.
create or replace function public.limit_posts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.posts where user_id = new.user_id and created_at > now() - interval '1 day') >= 20 then
    raise exception 'You can share up to 20 icons a day. Try again tomorrow.';
  end if;
  return new;
end $$;
drop trigger if exists posts_limit on public.posts;
create trigger posts_limit before insert on public.posts for each row execute function public.limit_posts();

-- ───────────────────────── Reports ─────────────────────────
-- One report per person per post. 3 reports hide the post until an admin looks at it.
create table if not exists public.reports (
  post_id uuid not null references public.posts(id) on delete cascade,
  reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, reporter_id)
);
alter table public.reports enable row level security;
drop policy if exists "Report posts" on public.reports;
create policy "Report posts" on public.reports for insert to authenticated
  with check (reporter_id = auth.uid() and not public.is_banned());
drop policy if exists "See your own reports, or all as admin" on public.reports;
create policy "See your own reports, or all as admin" on public.reports for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.reports from anon, authenticated;
grant select, insert on public.reports to authenticated;

create or replace function public.count_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.posts
     set report_count = (select count(*) from public.reports where post_id = new.post_id),
         hidden = hidden or (select count(*) from public.reports where post_id = new.post_id) >= 3
   where id = new.post_id;
  return new;
end $$;
drop trigger if exists reports_count on public.reports;
create trigger reports_count after insert on public.reports for each row execute function public.count_report();

-- ───────────────────────── Admin tools ─────────────────────────
-- Put a reported post back (clears its reports).
create or replace function public.admin_restore_post(post uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  delete from public.reports where post_id = post;
  update public.posts set hidden = false, report_count = 0 where id = post;
end $$;

-- Ban or unban an account. Banned accounts can't share or report, and their posts are hidden.
create or replace function public.admin_set_banned(target uuid, ban boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if target = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  update public.profiles set banned = ban where id = target;
end $$;

revoke execute on function public.admin_restore_post(uuid) from public, anon;
revoke execute on function public.admin_set_banned(uuid, boolean) from public, anon;
grant execute on function public.admin_restore_post(uuid) to authenticated;
grant execute on function public.admin_set_banned(uuid, boolean) to authenticated;
grant execute on function public.username_available(text) to anon, authenticated;

-- ───────────────────────── Image storage ─────────────────────────
-- Public bucket for shared icons: PNG/WebP only, up to 1 MB each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('icons', 'icons', true, 1048576, array['image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/png', 'image/webp'];

drop policy if exists "Upload icons to your own folder" on storage.objects;
create policy "Upload icons to your own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'icons' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned());
drop policy if exists "Delete your own icon files, or any as admin" on storage.objects;
create policy "Delete your own icon files, or any as admin" on storage.objects for delete to authenticated
  using (bucket_id = 'icons' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ───────────────────────── Profile pictures ─────────────────────────

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

-- ───────────────────────── Make yourself admin ─────────────────────────
-- After you've created your own account on the site, run this line once (with your username):
--   update public.profiles set is_admin = true where username = 'your_username';
