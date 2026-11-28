-- Monke Icon Maker: see when someone was last online (admins only, on their profile).
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
--
-- The site notes the time while you're using it signed in (at most every couple of minutes).
-- Only admins can see other people's times; everyone can see only their own.

create table if not exists public.last_seen (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now()
);
alter table public.last_seen enable row level security;
drop policy if exists "Admins see when people were online" on public.last_seen;
create policy "Admins see when people were online" on public.last_seen for select to authenticated
  using (public.is_admin() or user_id = auth.uid());
revoke all on public.last_seen from anon, authenticated;
grant select on public.last_seen to authenticated;

-- "I'm here": only ever updates your own time, and only if the last one is more than 2 minutes old.
create or replace function public.touch_last_seen() returns void
language sql security definer set search_path = public as $$
  insert into public.last_seen (user_id, seen_at)
  select auth.uid(), now() where auth.uid() is not null and exists (select 1 from public.profiles where id = auth.uid())
  on conflict (user_id) do update set seen_at = excluded.seen_at
  where public.last_seen.seen_at < now() - interval '2 minutes';
$$;
revoke execute on function public.touch_last_seen() from public, anon;
grant execute on function public.touch_last_seen() to authenticated;

-- Start everyone off with the last time they signed in, so there's something to see straight away.
insert into public.last_seen (user_id, seen_at)
select u.id, u.last_sign_in_at from auth.users u join public.profiles p on p.id = u.id
where u.last_sign_in_at is not null
on conflict (user_id) do nothing;
