-- Monke Icon Maker: safety filter update.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-20 first.)

create or replace function public.discord_re(part text) returns text
language sql immutable as $$
  select case part
    when 'got' then '(?:g[^a-z0-9]{0,3}[o0][^a-z0-9]{0,3}t|have|hav|haf|has|use|using|add|on|ur|your|yur|whats|wats|what[^a-z0-9]{0,2}s|what[^a-z0-9]{1,3}is|send|join)'
    when 'mid' then '(?:[^a-z0-9]{0,3}(?:a|an|ur|your|u|ya|any|my|me|me[^a-z0-9]{1,3}on|on|the))?[^a-z0-9]{0,3}'
    when 'disc' then '(?:d[^a-z0-9]{0,3}[i1!|l][^a-z0-9]{0,3}[s5$z][^a-z0-9]{0,3}[c(<k][^a-z0-9]{0,3}[o0](?:[^a-z0-9]{0,3}r[^a-z0-9]{0,3}d)?|dc(?![a-z0-9]))'
    when 'ask' then '^[^a-z0-9]*(?:(?:do|does|d)[^a-z0-9]{1,3})?(?:(?:u|you|ya|yu|ye)[^a-z0-9]{1,3})?(?:have|hav|got|use|has)(?:[^a-z0-9]{1,3}(?:it|one|that|ir))?[^a-z0-9]*$'
  end $$;

create or replace function public.censor_discord(t text, prev text default null) returns text
language plpgsql immutable as $$
declare g text := public.discord_re('got'); m text := public.discord_re('mid'); d text := public.discord_re('disc');
begin
  if t is null then return null; end if;
  t := regexp_replace(t, '(^|[^a-z0-9])' || g || m || d, '\1***', 'gi');
  if prev is not null and prev ~* ('(^|[^a-z0-9])' || g || m || '[^a-z0-9]*$') then
    t := regexp_replace(t, '^([^a-z0-9]*)' || d, '\1***', 'i');
  end if;
  return t;
end $$;

create or replace function public.censor_discord_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text; prev_id uuid; d text := public.discord_re('disc');
begin
  select c.body, c.id into prev, prev_id from public.comments c
   where c.user_id = new.user_id and c.created_at > now() - interval '15 minutes'
     and (tg_op = 'INSERT' or c.id <> new.id)
   order by c.created_at desc limit 1;
  new.body := public.censor_discord(new.body, prev);
  if tg_op = 'INSERT' and prev_id is not null and new.body ~* public.discord_re('ask') and prev ~* ('(^|[^a-z0-9])' || d) then
    update public.comments set body = regexp_replace(body, '(^|[^a-z0-9])' || d, '\1***', 'gi') where id = prev_id;
  end if;
  return new;
end $$;

update public.comments set body = public.censor_discord(body) where body is distinct from public.censor_discord(body);
update public.fan_messages set body = public.censor_discord(body) where body is distinct from public.censor_discord(body);
update public.posts set title = public.censor_discord(title) where title is distinct from public.censor_discord(title);
update public.profiles set display_name = public.censor_discord(display_name), bio = public.censor_discord(bio)
 where display_name is distinct from public.censor_discord(display_name) or bio is distinct from public.censor_discord(bio);
