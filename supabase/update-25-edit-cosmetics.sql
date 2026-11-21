-- Monke Icon Maker: edit cosmetics after adding them (⚙️ Settings → 🛡️ Admin → ➕ Add a cosmetic → ✏️ Edit).
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again. Needs update-24 first.

drop policy if exists "Admins edit cosmetics" on public.cosmetics;
create policy "Admins edit cosmetics" on public.cosmetics for update to authenticated
  using (public.is_admin())
  with check (public.is_admin() and image_path like (auth.uid()::text || '/cosmetics/%'));
grant update (name, slot, image_path, x, y, w, h) on public.cosmetics to authenticated;
