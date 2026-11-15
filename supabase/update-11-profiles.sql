-- Monke Icon Maker: profile descriptions and followers.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs the bad word filter from update-3. New projects: setup.sql has it all.)
--
-- Everyone can write a short description (up to 160 characters, through the bad word filter) and follow other
-- accounts. Follower counts are public. People can only follow and unfollow as themselves.

-- Descriptions
alter table public.profiles add column if not exists bio text check (bio is null or char_length(bio) <= 160);
revoke update on public.profiles from anon, authenticated;
grant update (display_name, avatar_path, bio) on public.profiles to authenticated;

-- The bad word filter now checks descriptions too.
create or replace function public.check_profile_words() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.has_bad_words(new.username) or public.has_bad_words(new.display_name) or public.has_bad_words(new.bio) then
    raise exception 'That has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  new.bio := nullif(btrim(new.bio), '');
  return new;
end $$;
drop trigger if exists profiles_bad_words on public.profiles;
create trigger profiles_bad_words before insert or update of username, display_name, bio on public.profiles
  for each row execute function public.check_profile_words();

-- Followers
create table if not exists public.follows (
  follower_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index if not exists follows_followee_idx on public.follows (followee_id);
alter table public.follows enable row level security;
drop policy if exists "Follows are public" on public.follows;
create policy "Follows are public" on public.follows for select using (true);
drop policy if exists "Follow as yourself" on public.follows;
create policy "Follow as yourself" on public.follows for insert to authenticated
  with check (follower_id = auth.uid() and not public.is_banned());
drop policy if exists "Unfollow as yourself" on public.follows;
create policy "Unfollow as yourself" on public.follows for delete to authenticated using (follower_id = auth.uid());
revoke all on public.follows from anon, authenticated;
grant select on public.follows to anon, authenticated;
grant insert (followee_id) on public.follows to authenticated;
grant delete on public.follows to authenticated;

-- Followers / following / icons counts for a profile.
create or replace function public.profile_stats(p_user uuid)
returns table (followers int, following int, icons int)
language sql stable security definer set search_path = public as $$
  select (select count(*)::int from public.follows where followee_id = p_user),
         (select count(*)::int from public.follows where follower_id = p_user),
         (select count(*)::int from public.posts where user_id = p_user and not hidden);
$$;
grant execute on function public.profile_stats(uuid) to anon, authenticated;
