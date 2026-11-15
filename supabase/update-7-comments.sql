-- Monke Icon Maker: comments on gallery icons.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs the bad word filter from update-3 to have been run. New projects: setup.sql has it all.)
--
-- Comments are up to 200 characters and go through the bad word filter. People can delete their own comments,
-- and the owner of an icon can delete comments on it. 3 reports hide a comment until an admin checks it.

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 200),
  report_count int not null default 0,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists comments_post_idx on public.comments (post_id, created_at);

alter table public.comments enable row level security;
drop policy if exists "See visible comments" on public.comments;
create policy "See visible comments" on public.comments for select using (
  (not hidden and not exists (select 1 from public.profiles p where p.id = comments.user_id and p.banned))
  or user_id = auth.uid() or public.is_admin());
drop policy if exists "Comment as yourself" on public.comments;
create policy "Comment as yourself" on public.comments for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned()
              and exists (select 1 from public.posts p where p.id = post_id and not p.hidden));
drop policy if exists "Delete your comments, comments on your icons, or any as admin" on public.comments;
create policy "Delete your comments, comments on your icons, or any as admin" on public.comments for delete to authenticated
  using (user_id = auth.uid() or public.is_admin()
         or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid()));
revoke all on public.comments from anon, authenticated;
grant select on public.comments to anon, authenticated;
grant insert (post_id, body) on public.comments to authenticated;
grant delete on public.comments to authenticated;

-- Bad words, length and spam checks.
create or replace function public.check_comment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.body := btrim(new.body);
  if public.has_bad_words(new.body) then
    raise exception 'That comment has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  if (select count(*) from public.comments where user_id = new.user_id and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You can post up to 30 comments an hour. Try again later.';
  end if;
  return new;
end $$;
drop trigger if exists comments_check on public.comments;
create trigger comments_check before insert on public.comments for each row execute function public.check_comment();

-- Comment totals per icon (only counting comments the person looking can see).
create or replace view public.comment_counts with (security_invoker = on) as
  select post_id, count(*)::int as n from public.comments group by post_id;
grant select on public.comment_counts to anon, authenticated;

-- Reporting comments: one report per person per comment, 3 reports hide it.
create table if not exists public.comment_reports (
  comment_id uuid not null references public.comments(id) on delete cascade,
  reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, reporter_id)
);
alter table public.comment_reports enable row level security;
drop policy if exists "Report comments" on public.comment_reports;
create policy "Report comments" on public.comment_reports for insert to authenticated
  with check (reporter_id = auth.uid() and not public.is_banned());
drop policy if exists "See your own comment reports, or all as admin" on public.comment_reports;
create policy "See your own comment reports, or all as admin" on public.comment_reports for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin());
revoke all on public.comment_reports from anon, authenticated;
grant select on public.comment_reports to authenticated;
grant insert (comment_id) on public.comment_reports to authenticated;

create or replace function public.count_comment_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.comments
     set report_count = (select count(*) from public.comment_reports where comment_id = new.comment_id),
         hidden = hidden or (select count(*) from public.comment_reports where comment_id = new.comment_id) >= 3
   where id = new.comment_id;
  return new;
end $$;
drop trigger if exists comment_reports_count on public.comment_reports;
create trigger comment_reports_count after insert on public.comment_reports for each row execute function public.count_comment_report();

-- Admins can put a reported comment back.
create or replace function public.admin_restore_comment(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  delete from public.comment_reports where comment_id = target;
  update public.comments set hidden = false, report_count = 0 where id = target;
end $$;
revoke execute on function public.admin_restore_comment(uuid) from public, anon;
grant execute on function public.admin_restore_comment(uuid) to authenticated;
