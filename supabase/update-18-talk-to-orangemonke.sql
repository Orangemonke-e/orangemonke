-- Monke Icon Maker: "Talk to Orangemonke". Signed-in people send Orangemonke a message, and every day one random
-- message from one random person is picked to show to the admin.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs the bad word filter from update-3. New projects: setup.sql has it all.)
--
-- Messages are private: people only see their own (and whether it was picked); admins see them all.
-- Up to 300 characters, through the bad word filter, one message per person per day (UK time).

create table if not exists public.fan_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 300),
  picked_on date,                -- the day it was shown to Orangemonke (null = still waiting)
  created_at timestamptz not null default now()
);
create index if not exists fan_messages_user_idx on public.fan_messages (user_id, created_at desc);
create index if not exists fan_messages_waiting_idx on public.fan_messages (user_id) where picked_on is null;
create unique index if not exists fan_messages_one_a_day on public.fan_messages (picked_on) where picked_on is not null;

alter table public.fan_messages enable row level security;
drop policy if exists "See your own messages, or all as admin" on public.fan_messages;
create policy "See your own messages, or all as admin" on public.fan_messages for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists "Send as yourself" on public.fan_messages;
create policy "Send as yourself" on public.fan_messages for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned());
drop policy if exists "Delete your own messages, or any as admin" on public.fan_messages;
create policy "Delete your own messages, or any as admin" on public.fan_messages for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());
revoke all on public.fan_messages from anon, authenticated;
grant select, delete on public.fan_messages to authenticated;
grant insert (body) on public.fan_messages to authenticated;

create or replace function public.uk_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/London')::date $$;

create or replace function public.check_fan_message() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.body := btrim(new.body);
  new.picked_on := null;
  if public.has_bad_words(new.body) then
    raise exception 'That message has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.fan_messages where user_id = new.user_id
             and (created_at at time zone 'Europe/London')::date = public.uk_today()) then
    raise exception 'You can send one message a day. Come back tomorrow!';
  end if;
  return new;
end $$;
drop trigger if exists fan_messages_check on public.fan_messages;
create trigger fan_messages_check before insert on public.fan_messages for each row execute function public.check_fan_message();

-- Today's message (admins only). The first time it's asked for each day, it picks a random person who has a
-- message waiting, then one of their waiting messages at random, so people who send lots don't win more often.
-- p_skip = true deletes today's message (e.g. if it's mean) and picks another.
create or replace function public.todays_fan_message(p_skip boolean default false)
returns table (id uuid, body text, created_at timestamptz, picked_on date, user_id uuid, username text, display_name text, avatar_path text, waiting int)
language plpgsql security definer set search_path = public as $$
declare d date := public.uk_today(); who uuid;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if p_skip then delete from public.fan_messages m where m.picked_on = d; end if;
  if not exists (select 1 from public.fan_messages m where m.picked_on = d) then
    select m.user_id into who from public.fan_messages m join public.profiles p on p.id = m.user_id
     where m.picked_on is null and not p.banned group by m.user_id order by random() limit 1;
    if who is not null then
      update public.fan_messages set picked_on = d
       where fan_messages.id = (select m.id from public.fan_messages m where m.user_id = who and m.picked_on is null order by random() limit 1);
    end if;
  end if;
  return query
    select m.id, m.body, m.created_at, m.picked_on, m.user_id, p.username, p.display_name, p.avatar_path,
           (select count(*)::int from public.fan_messages w join public.profiles wp on wp.id = w.user_id where w.picked_on is null and not wp.banned)
      from public.fan_messages m join public.profiles p on p.id = m.user_id where m.picked_on = d
    union all
    select null, null, null, null, null, null, null, null,
           (select count(*)::int from public.fan_messages w join public.profiles wp on wp.id = w.user_id where w.picked_on is null and not wp.banned)
     where not exists (select 1 from public.fan_messages m where m.picked_on = d);
end $$;
revoke execute on function public.todays_fan_message(boolean) from public, anon;
grant execute on function public.todays_fan_message(boolean) to authenticated;
