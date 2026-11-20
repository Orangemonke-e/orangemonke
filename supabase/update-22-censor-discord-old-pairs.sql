-- Monke Icon Maker: censor "ask for Discord" pairs that were posted before the censoring was installed.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-21 first.)
--
-- update-20/21 check each old comment on its own. This also looks at each person's comments in pairs (posted within
-- 15 minutes of each other), like the check on new comments does: "I love disco" + "Do u have", "Got" + "Discord".

with pairs as (
  select id, body, created_at,
         lag(id) over w as prev_id, lag(body) over w as prev_body, lag(created_at) over w as prev_at
    from public.comments window w as (partition by user_id order by created_at)
)
-- the other order: "…disco…" then "do u have" → censor the first one
update public.comments c set body = regexp_replace(c.body, '(^|[^a-z0-9])' || public.discord_re('disc'), '\1***', 'gi')
  from pairs p
 where c.id = p.prev_id and p.created_at - p.prev_at < interval '15 minutes'
   and p.body ~* public.discord_re('ask') and c.body ~* ('(^|[^a-z0-9])' || public.discord_re('disc'));

with pairs as (
  select id, body, created_at, lag(body) over w as prev_body, lag(created_at) over w as prev_at
    from public.comments window w as (partition by user_id order by created_at)
)
-- "Got" then "Discord" → censor the second one
update public.comments c set body = public.censor_discord(p.body, p.prev_body)
  from pairs p
 where c.id = p.id and p.prev_at is not null and p.created_at - p.prev_at < interval '15 minutes'
   and p.body is distinct from public.censor_discord(p.body, p.prev_body);
