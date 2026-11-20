-- Monke Icon Maker: safety filter update.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-18 first. New projects: setup.sql has it all.)

create or replace function public.discord_re(part text) returns text
language sql immutable as $$
  select case part
    when 'got' then 'g[^a-z0-9]{0,3}[o0][^a-z0-9]{0,3}t'
    when 'mid' then '(?:[^a-z0-9]{0,3}(?:a|an|ur|your|u|ya|any))?[^a-z0-9]{0,3}'
    when 'disc' then 'd[^a-z0-9]{0,3}[i1!|l][^a-z0-9]{0,3}[s5$z][^a-z0-9]{0,3}[c(<k][^a-z0-9]{0,3}[o0](?:[^a-z0-9]{0,3}r[^a-z0-9]{0,3}d)?'
  end $$;

create or replace function public.censor_discord(t text, prev text default null) returns text
language plpgsql immutable as $$
declare g text := public.discord_re('got'); m text := public.discord_re('mid'); d text := public.discord_re('disc');
begin
  if t is null then return null; end if;
  t := regexp_replace(t, '(^|[^a-z0-9])' || g || m || d, '\1***', 'gi');
  if prev is not null and prev ~* (g || m || '[^a-z0-9]*$') then
    t := regexp_replace(t, '^([^a-z0-9]*)' || d, '\1***', 'i');
  end if;
  return t;
end $$;
grant execute on function public.censor_discord(text, text) to anon, authenticated;

create or replace function public.censor_discord_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text;
begin
  select c.body into prev from public.comments c
   where c.user_id = new.user_id and c.created_at > now() - interval '15 minutes'
     and (tg_op = 'INSERT' or c.id <> new.id)
   order by c.created_at desc limit 1;
  new.body := public.censor_discord(new.body, prev);
  return new;
end $$;
drop trigger if exists aa_censor_discord on public.comments;
create trigger aa_censor_discord before insert or update of body on public.comments for each row execute function public.censor_discord_comment();

create or replace function public.censor_discord_fan() returns trigger
language plpgsql security definer set search_path = public as $$
begin new.body := public.censor_discord(new.body); return new; end $$;
drop trigger if exists aa_censor_discord on public.fan_messages;
create trigger aa_censor_discord before insert or update of body on public.fan_messages for each row execute function public.censor_discord_fan();

create or replace function public.censor_discord_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin new.title := public.censor_discord(new.title); return new; end $$;
drop trigger if exists aa_censor_discord on public.posts;
create trigger aa_censor_discord before insert or update of title on public.posts for each row execute function public.censor_discord_post();

create or replace function public.censor_discord_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin new.display_name := public.censor_discord(new.display_name); new.bio := public.censor_discord(new.bio); return new; end $$;
drop trigger if exists aa_censor_discord on public.profiles;
create trigger aa_censor_discord before insert or update of display_name, bio on public.profiles for each row execute function public.censor_discord_profile();

update public.comments set body = public.censor_discord(body) where body is distinct from public.censor_discord(body);
update public.fan_messages set body = public.censor_discord(body) where body is distinct from public.censor_discord(body);
update public.posts set title = public.censor_discord(title) where title is distinct from public.censor_discord(title);
update public.profiles set display_name = public.censor_discord(display_name), bio = public.censor_discord(bio)
 where display_name is distinct from public.censor_discord(display_name) or bio is distinct from public.censor_discord(bio);
