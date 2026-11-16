-- Monke Icon Maker: lock an icon in its section (Monke icons or Off topic).
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-16 (off topic) first. New projects: setup.sql has it all.)
--
-- The person who shared an icon can lock it in, so it stays where it is. An admin can force lock anyone's icon.
-- Only an admin can unlock. While an icon is locked, only an admin can move it.
-- Locks are private: only the icon's owner and admins can see them.

create table if not exists public.post_locks (
  post_id uuid primary key references public.posts(id) on delete cascade,
  by_admin boolean not null default false,   -- true when an admin locked someone else's icon
  locked_at timestamptz not null default now()
);
alter table public.post_locks enable row level security;
revoke all on public.post_locks from anon, authenticated;
grant select on public.post_locks to authenticated;
drop policy if exists "owner or admin can see locks" on public.post_locks;
create policy "owner or admin can see locks" on public.post_locks for select to authenticated
  using (public.is_admin() or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid()));

-- Lock (p_lock = true): the owner or an admin. Unlock (p_lock = false): admins only.
create or replace function public.set_post_lock(p_post uuid, p_lock boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  if auth.uid() is null or public.is_banned() then return false; end if;
  select user_id into owner from public.posts where id = p_post;
  if owner is null then return false; end if;
  if coalesce(p_lock, false) then
    if owner <> auth.uid() and not public.is_admin() then return false; end if;
    insert into public.post_locks (post_id, by_admin) values (p_post, owner <> auth.uid())
      on conflict (post_id) do update set by_admin = public.post_locks.by_admin or excluded.by_admin;
  else
    if not public.is_admin() then return false; end if;
    delete from public.post_locks where post_id = p_post;
  end if;
  return true;
end $$;
revoke execute on function public.set_post_lock(uuid, boolean) from public, anon;
grant execute on function public.set_post_lock(uuid, boolean) to authenticated;

-- Moving an icon: the owner (unless it's locked) or an admin.
create or replace function public.set_post_topic(p_post uuid, p_off boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  if auth.uid() is null or public.is_banned() then return false; end if;
  update public.posts set off_topic = coalesce(p_off, false)
   where id = p_post
     and (public.is_admin() or (user_id = auth.uid() and not exists (select 1 from public.post_locks l where l.post_id = p_post)))
  returning true into ok;
  return coalesce(ok, false);
end $$;
revoke execute on function public.set_post_topic(uuid, boolean) from public, anon;
grant execute on function public.set_post_topic(uuid, boolean) to authenticated;
