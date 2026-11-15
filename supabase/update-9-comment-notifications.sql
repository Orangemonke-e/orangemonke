-- Monke Icon Maker: notifications for comments.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-7 (comments) and update-8 (notifications) first. New projects: setup.sql has it all.)
--
-- When someone comments on an icon, the icon's owner and everyone else who commented on it get a notification
-- (if they turned notifications on while signed in). Nobody is notified about their own comment.
-- A comment can only trigger its notifications once, right after it's posted, by the person who wrote it.
-- The list of devices to notify is only ever read by the sender function, never by the site.

alter table public.comments add column if not exists notified boolean not null default false;

-- Step 1 (as the commenter): "I just posted this comment, please notify people." Only works once, within 5 minutes.
create or replace function public.claim_comment_notification(p_comment uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  update public.comments set notified = true
   where id = p_comment and user_id = auth.uid() and not notified and created_at > now() - interval '5 minutes'
     and not public.is_banned()
  returning true into ok;
  return coalesce(ok, false);
end $$;

-- Step 2 (sender function only): which devices to notify, and what to say.
create or replace function public.comment_push_targets(p_comment uuid)
returns table (endpoint text, p256dh text, auth_secret text, kind text, author_name text, post_title text, body text, post_id uuid)
language sql stable security definer set search_path = public as $$
  with c as (select * from public.comments where id = p_comment),
       p as (select posts.* from public.posts join c on posts.id = c.post_id),
       who as (
         select p.user_id as uid, 'owner'::text as kind from p, c where p.user_id <> c.user_id
         union
         select distinct cm.user_id, 'thread' from public.comments cm, c, p
          where cm.post_id = c.post_id and cm.id <> c.id and cm.user_id <> c.user_id and cm.user_id <> p.user_id
       )
  select s.endpoint, s.p256dh, s.auth_secret, who.kind,
         (select display_name from public.profiles where id = c.user_id), coalesce(p.title, ''), c.body, c.post_id
    from who join public.push_subscriptions s on s.user_id = who.uid, c, p;
$$;

-- Sender function only: forget devices whose browser says they're gone.
create or replace function public.service_remove_push(p_endpoints text[]) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = any(p_endpoints);
$$;

revoke execute on function public.claim_comment_notification(uuid) from public, anon;
grant execute on function public.claim_comment_notification(uuid) to authenticated;
revoke execute on function public.comment_push_targets(uuid) from public, anon, authenticated;
revoke execute on function public.service_remove_push(text[]) from public, anon, authenticated;
grant execute on function public.comment_push_targets(uuid) to service_role;
grant execute on function public.service_remove_push(text[]) to service_role;
