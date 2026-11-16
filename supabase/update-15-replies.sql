-- Monke Icon Maker: replies to comments, and a notification when someone replies to you.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-7 (comments) and update-9 (comment notifications) first. New projects: setup.sql has it all.)
--
-- Comments can say which comment they're replying to. The person you replied to gets a "replied to you"
-- notification (if they turned notifications on while signed in). If the original comment is deleted, the reply stays.

alter table public.comments add column if not exists reply_to uuid references public.comments(id) on delete set null;
grant insert (post_id, body, reply_to) on public.comments to authenticated;

-- Bad words, length and spam checks. A reply must be to a comment on the same icon.
create or replace function public.check_comment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.body := btrim(new.body);
  if public.has_bad_words(new.body) then
    raise exception 'That comment has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  if (select count(*) from public.comments where user_id = new.user_id and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You can post up to 30 comments an hour. Try again later.';
  end if;
  if new.reply_to is not null and not exists (select 1 from public.comments where id = new.reply_to and post_id = new.post_id) then
    raise exception 'That comment isn''t there any more.';
  end if;
  return new;
end $$;

-- Sender function only: which devices to notify, and what to say. Each person gets one notification: "replied to
-- you" beats "comment on your icon", which beats "comment on an icon you commented on". Never about your own comment.
create or replace function public.comment_push_targets(p_comment uuid)
returns table (endpoint text, p256dh text, auth_secret text, kind text, author_name text, post_title text, body text, post_id uuid)
language sql stable security definer set search_path = public as $$
  with c as (select * from public.comments where id = p_comment),
       p as (select posts.* from public.posts join c on posts.id = c.post_id),
       who as (
         select distinct on (uid) uid, kind from (
           select r.user_id as uid, 'reply'::text as kind, 1 as rank from public.comments r, c where r.id = c.reply_to and r.user_id <> c.user_id
           union all
           select p.user_id, 'owner', 2 from p, c where p.user_id <> c.user_id
           union all
           select cm.user_id, 'thread', 3 from public.comments cm, c where cm.post_id = c.post_id and cm.id <> c.id and cm.user_id <> c.user_id
         ) x order by uid, rank
       )
  select s.endpoint, s.p256dh, s.auth_secret, who.kind,
         (select display_name from public.profiles where id = c.user_id), coalesce(p.title, ''), c.body, c.post_id
    from who join public.push_subscriptions s on s.user_id = who.uid, c, p;
$$;
revoke execute on function public.comment_push_targets(uuid) from public, anon, authenticated;
grant execute on function public.comment_push_targets(uuid) to service_role;
