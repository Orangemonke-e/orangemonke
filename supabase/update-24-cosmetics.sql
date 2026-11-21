-- Monke Icon Maker: cosmetics added from the website (⚙️ Settings → 🛡️ Admin → ➕ Add a cosmetic).
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
--
-- Everyone can see them; only admins can add or remove them. The pictures live in the admin's folder of the "icons" bucket.

create table if not exists public.cosmetics (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 40),
  slot text not null default 'head' check (slot in ('head', 'body', 'other')),
  image_path text not null check (char_length(image_path) < 200),
  x int not null, y int not null, w int not null check (w between 1 and 4096), h int not null check (h between 1 and 4096),
  created_by uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.cosmetics enable row level security;
drop policy if exists "Everyone can see cosmetics" on public.cosmetics;
create policy "Everyone can see cosmetics" on public.cosmetics for select using (true);
drop policy if exists "Admins add cosmetics" on public.cosmetics;
create policy "Admins add cosmetics" on public.cosmetics for insert to authenticated
  with check (public.is_admin() and created_by = auth.uid() and image_path like (auth.uid()::text || '/cosmetics/%'));
drop policy if exists "Admins remove cosmetics" on public.cosmetics;
create policy "Admins remove cosmetics" on public.cosmetics for delete to authenticated using (public.is_admin());
revoke all on public.cosmetics from anon, authenticated;
grant select on public.cosmetics to anon, authenticated;
grant insert (name, slot, image_path, x, y, w, h) on public.cosmetics to authenticated;
grant delete on public.cosmetics to authenticated;
