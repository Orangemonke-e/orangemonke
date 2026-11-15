-- Monke Icon Maker: likes, and notifications for new followers.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-8 (notifications) and update-11 (followers) first. New projects: setup.sql has it all.)
--
-- Likes: each signed-in person can like each icon once. Every icon keeps a like count, so the gallery can show the
-- most liked icons first.
-- Follower notifications: when someone follows you, you get a notification (if you turned notifications on while
-- signed in). Following and unfollowing someone over and over only notifies them once a day.

-- ───────── Likes ─────────
alter table public.posts add column if not exists like_count int not null default 0;
create index if not exists posts_likes_idx on public.posts (like_count desc, created_at desc);

create table if not exists public.likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.likes enable row level security;
drop policy if exists "Likes are public" on public.likes;
create policy "Likes are public" on public.likes for select using (true);
drop policy if exists "Like as yourself" on public.likes;
create policy "Like as yourself" on public.likes for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned()
              and exists (select 1 from public.posts p where p.id = post_id and not p.hidden));
drop policy if exists "Unlike as yourself" on public.likes;
create policy "Unlike as yourself" on public.likes for delete to authenticated using (user_id = auth.uid());
revoke all on public.likes from anon, authenticated;
grant select on public.likes to anon, authenticated;
grant insert (post_id) on public.likes to authenticated;
grant delete on public.likes to authenticated;

-- Keep each icon's like count up to date.
create or replace function public.count_likes() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid := coalesce(new.post_id, old.post_id);
begin
  update public.posts set like_count = (select count(*) from public.likes where post_id = pid) where id = pid;
  return null;
end $$;
drop trigger if exists likes_count on public.likes;
create trigger likes_count after insert or delete on public.likes for each row execute function public.count_likes();
-- (in case any likes already exist)
update public.posts p set like_count = (select count(*) from public.likes l where l.post_id = p.id);

-- ───────── Follower notifications ─────────
create table if not exists public.follow_notices (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (follower_id, followee_id)
);
alter table public.follow_notices enable row level security;   -- no policies: only used by the functions below
revoke all on public.follow_notices from anon, authenticated;

-- Step 1 (as the new follower): "I just followed this person, please tell them." Returns the follower's id,
-- or nothing if they don't really follow them, or were already announced in the last day.
create or replace function public.claim_follow_notification(p_followee uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or public.is_banned() then return null; end if;
  if not exists (select 1 from public.follows where follower_id = me and followee_id = p_followee
                 and created_at > now() - interval '5 minutes') then return null; end if;
  if exists (select 1 from public.follow_notices where follower_id = me and followee_id = p_followee
             and sent_at > now() - interval '1 day') then return null; end if;
  insert into public.follow_notices (follower_id, followee_id) values (me, p_followee)
  on conflict (follower_id, followee_id) do update set sent_at = now();
  return me;
end $$;

-- Step 2 (sender function only): the new follower's name, and the devices of the person they followed.
create or replace function public.follow_push_targets(p_follower uuid, p_followee uuid)
returns table (endpoint text, p256dh text, auth_secret text, follower_name text, follower_username text)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth_secret, f.display_name, f.username
    from public.push_subscriptions s, public.profiles f
   where s.user_id = p_followee and f.id = p_follower and p_follower <> p_followee;
$$;

revoke execute on function public.claim_follow_notification(uuid) from public, anon;
grant execute on function public.claim_follow_notification(uuid) to authenticated;
revoke execute on function public.follow_push_targets(uuid, uuid) from public, anon, authenticated;
grant execute on function public.follow_push_targets(uuid, uuid) to service_role;
