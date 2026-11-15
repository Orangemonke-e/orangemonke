-- Monke Icon Maker: update notifications (web push).
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (New projects don't need this: setup.sql already includes it.)
--
-- Stores the devices that turned on notifications. Nobody can read this list from the site: devices can only add
-- or remove themselves, and only an admin (through the notify-update function) can get the list to send to.

create table if not exists public.push_subscriptions (
  endpoint text primary key,
  p256dh text not null,
  auth_secret text not null,
  user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;   -- no policies: no direct access from the site
revoke all on public.push_subscriptions from anon, authenticated;

-- Only real browser push services are accepted (Chrome/Android, Firefox, Safari/iPhone, Edge/Windows).
create or replace function public.is_push_endpoint(url text) returns boolean
language sql immutable as $$
  select url ~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/'
     and char_length(url) <= 1000;
$$;

-- Called by the site when someone turns notifications on (or to refresh their device's details).
create or replace function public.subscribe_push(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_push_endpoint(p_endpoint) then raise exception 'Not a browser push address'; end if;
  if p_p256dh !~ '^[A-Za-z0-9_-]{80,100}$' or p_auth !~ '^[A-Za-z0-9_-]{16,32}$' then raise exception 'Bad push keys'; end if;
  insert into public.push_subscriptions (endpoint, p256dh, auth_secret, user_id)
  values (p_endpoint, p_p256dh, p_auth, auth.uid())
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth_secret = excluded.auth_secret,
    user_id = coalesce(excluded.user_id, push_subscriptions.user_id);
end $$;

-- Called by the site when someone turns notifications off.
create or replace function public.unsubscribe_push(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint;
$$;

-- For the notify-update function: the devices to send to (admins only).
create or replace function public.admin_push_targets() returns table (endpoint text, p256dh text, auth_secret text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query select s.endpoint, s.p256dh, s.auth_secret from public.push_subscriptions s;
end $$;

-- For the notify-update function: forget devices whose browser says they're gone (admins only).
create or replace function public.admin_remove_push(p_endpoints text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  delete from public.push_subscriptions where endpoint = any(p_endpoints);
end $$;

revoke execute on function public.subscribe_push(text, text, text) from public;
revoke execute on function public.unsubscribe_push(text) from public;
revoke execute on function public.admin_push_targets() from public, anon;
revoke execute on function public.admin_remove_push(text[]) from public, anon;
grant execute on function public.subscribe_push(text, text, text) to anon, authenticated;
grant execute on function public.unsubscribe_push(text) to anon, authenticated;
grant execute on function public.admin_push_targets() to authenticated;
grant execute on function public.admin_remove_push(text[]) to authenticated;
