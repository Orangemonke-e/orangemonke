-- Monke Icon Maker: safety filter update.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-22 first.)

create or replace function public.hash_out(t text, pat text) returns text
language plpgsql immutable as $$
declare pos int; s text; n int := 0;
begin
  if t is null then return null; end if;
  loop
    n := n + 1; exit when n > 50;
    pos := regexp_instr(t, pat, 1, 1, 0, 'i'); exit when pos = 0;
    s := regexp_substr(t, pat, 1, 1, 'i'); exit when s is null or s = '';
    t := overlay(t placing repeat('#', length(s)) from pos for length(s));
  end loop;
  return t;
end $$;

create or replace function public.censor_discord(t text, prev text default null) returns text
language plpgsql immutable as $$
declare g text := public.discord_re('got'); m text := public.discord_re('mid'); d text := public.discord_re('disc');
begin
  if t is null then return null; end if;
  t := public.hash_out(t, '(?<![a-z0-9])' || g || m || d);
  if prev is not null and prev ~* ('(^|[^a-z0-9])' || g || m || '[^a-z0-9]*$') then
    t := public.hash_out(t, '(?<=^[^a-z0-9]{0,5})' || d);
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
    update public.comments set body = public.hash_out(body, '(?<![a-z0-9])' || d) where id = prev_id;
  end if;
  return new;
end $$;

update public.comments set body = replace(body, '***', '###') where body like '%***%';
update public.fan_messages set body = replace(body, '***', '###') where body like '%***%';
update public.posts set title = replace(title, '***', '###') where title like '%***%';
update public.profiles set display_name = replace(display_name, '***', '###'), bio = replace(bio, '***', '###')
 where display_name like '%***%' or bio like '%***%';
