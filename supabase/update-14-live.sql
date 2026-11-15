-- Monke Icon Maker: live updates.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (New projects don't need this: setup.sql already includes it.)
--
-- Turns on Supabase Realtime for the gallery, so new icons, likes, reactions, comments and follows show up for
-- everyone straight away, without refreshing. Realtime follows the same rules as the rest of the site: people only
-- receive changes they're allowed to see. Private tables (like the notification devices) are not included.

do $$ begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

do $$ declare t text; begin
  foreach t in array array['posts', 'comments', 'reactions', 'follows'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
