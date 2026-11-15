-- Monke Icon Maker: emoji reactions on gallery icons.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (New projects don't need this: setup.sql already includes it.)
--
-- Each signed-in person can add each reaction once per icon, and take it back.
-- The reactions are: monke (the custom orange monke), heart, fire, laugh, wow, thumbs.

create table if not exists public.reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('monke', 'heart', 'fire', 'laugh', 'wow', 'thumbs')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, emoji)
);
create index if not exists reactions_post_idx on public.reactions (post_id);

alter table public.reactions enable row level security;
drop policy if exists "Reactions are public" on public.reactions;
create policy "Reactions are public" on public.reactions for select using (true);
drop policy if exists "React as yourself" on public.reactions;
create policy "React as yourself" on public.reactions for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned()
              and exists (select 1 from public.posts p where p.id = post_id and not p.hidden));
drop policy if exists "Take back your own reactions" on public.reactions;
create policy "Take back your own reactions" on public.reactions for delete to authenticated
  using (user_id = auth.uid());
revoke all on public.reactions from anon, authenticated;
grant select on public.reactions to anon, authenticated;
grant insert (post_id, emoji) on public.reactions to authenticated;
grant delete on public.reactions to authenticated;

-- Totals per icon, so the site doesn't have to download every single reaction.
create or replace view public.reaction_counts with (security_invoker = on) as
  select post_id, emoji, count(*)::int as n from public.reactions group by post_id, emoji;
grant select on public.reaction_counts to anon, authenticated;
