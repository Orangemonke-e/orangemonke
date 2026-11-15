-- Monke Icon Maker: Remix.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (New projects don't need this: setup.sql already includes it.)
--
-- Icons shared to the gallery also save their design settings (colours, accessories, background and so on), so
-- other people can tap Remix to load that design into the editor. Name tags aren't saved. If an icon was made
-- by remixing another one, it remembers which, so the original creator gets the credit.

alter table public.posts add column if not exists design jsonb
  check (design is null or (jsonb_typeof(design) = 'object' and pg_column_size(design) < 4000));
alter table public.posts add column if not exists remix_of uuid references public.posts(id) on delete set null;
grant insert (image_path, title, design, remix_of) on public.posts to authenticated;
