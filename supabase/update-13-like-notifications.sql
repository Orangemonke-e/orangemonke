-- Monke Icon Maker: notifications when someone likes your icon.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-12 (likes) first. New projects: setup.sql has it all.)
--
-- When someone likes one of your icons, you get a notification (if you turned notifications on while signed in).
-- You're never notified about your own likes, and liking/unliking the same icon over and over only notifies once a day.

create table if not exists public.like_notices (
  liker_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (liker_id, post_id)
);
alter table public.like_notices enable row level security;   -- no policies: only used by the functions below
revoke all on public.like_notices from anon, authenticated;

-- Step 1 (as the person who liked): "I just liked this icon, please tell its owner." Returns the liker's id, or
-- nothing if they don't really like it, it's their own icon, or the owner was already told in the last day.
create or replace function public.claim_like_notification(p_post uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or public.is_banned() then return null; end if;
  if not exists (select 1 from public.likes l join public.posts p on p.id = l.post_id
                  where l.post_id = p_post and l.user_id = me and p.user_id <> me
                    and l.created_at > now() - interval '5 minutes') then return null; end if;
  if exists (select 1 from public.like_notices where liker_id = me and post_id = p_post
             and sent_at > now() - interval '1 day') then return null; end if;
  insert into public.like_notices (liker_id, post_id) values (me, p_post)
  on conflict (liker_id, post_id) do update set sent_at = now();
  return me;
end $$;

-- Step 2 (sender function only): the liker's name, the icon's title, and the owner's devices.
create or replace function public.like_push_targets(p_liker uuid, p_post uuid)
returns table (endpoint text, p256dh text, auth_secret text, liker_name text, post_title text)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth_secret, l.display_name, coalesce(p.title, '')
    from public.posts p
    join public.push_subscriptions s on s.user_id = p.user_id
    join public.profiles l on l.id = p_liker
   where p.id = p_post and p.user_id <> p_liker;
$$;

revoke execute on function public.claim_like_notification(uuid) from public, anon;
grant execute on function public.claim_like_notification(uuid) to authenticated;
revoke execute on function public.like_push_targets(uuid, uuid) from public, anon, authenticated;
grant execute on function public.like_push_targets(uuid, uuid) to service_role;
