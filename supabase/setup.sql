-- Monke Icon Maker: community gallery setup for Supabase.
-- Run this once in your Supabase project: Dashboard > SQL Editor > New query > paste all of this > Run.
-- It is safe to run again; it won't delete anything.

-- ───────────────────────── Profiles ─────────────────────────
-- One row per account. Usernames are unique (ignoring capital letters) and can't be changed.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 30),
  avatar_url text,                       -- empty means the default grey monke
  is_admin boolean not null default false,
  banned boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_username_key on public.profiles (lower(username));

-- Makes the profile when someone signs up, from the username and display name they typed.
-- If the username is already taken, the whole sign-up is cancelled.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, display_name)
  values (new.id,
          lower(new.raw_user_meta_data->>'username'),
          btrim(coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username')));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Lets the sign-up form say "that username is taken" before you submit.
create or replace function public.username_available(name text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.profiles where lower(username) = lower(name));
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select banned from public.profiles where id = auth.uid()), false);
$$;

alter table public.profiles enable row level security;
grant select on public.profiles to anon, authenticated;
drop policy if exists "Profiles are public" on public.profiles;
create policy "Profiles are public" on public.profiles for select using (true);
drop policy if exists "Edit your own profile" on public.profiles;
create policy "Edit your own profile" on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
-- People may only change their display name (not their username, admin or banned flags).
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (display_name) on public.profiles to authenticated;

-- ───────────────────────── Posts ─────────────────────────
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  image_path text not null,              -- file in the "icons" storage bucket
  title text check (title is null or char_length(title) <= 40),
  report_count int not null default 0,
  hidden boolean not null default false, -- hidden automatically after 3 reports
  created_at timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);

alter table public.posts enable row level security;
drop policy if exists "See visible posts" on public.posts;
create policy "See visible posts" on public.posts for select using (
  (not hidden and not exists (select 1 from public.profiles p where p.id = posts.user_id and p.banned))
  or user_id = auth.uid() or public.is_admin());
drop policy if exists "Share your own icons" on public.posts;
create policy "Share your own icons" on public.posts for insert to authenticated with check (
  user_id = auth.uid() and not public.is_banned()
  and image_path like auth.uid()::text || '/%');
drop policy if exists "Delete your own posts, or any as admin" on public.posts;
create policy "Delete your own posts, or any as admin" on public.posts for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.posts from anon, authenticated;
grant select on public.posts to anon, authenticated;
grant insert (image_path, title) on public.posts to authenticated;
grant delete on public.posts to authenticated;

-- Spam guard: at most 20 shares per account per day.
create or replace function public.limit_posts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.posts where user_id = new.user_id and created_at > now() - interval '1 day') >= 20 then
    raise exception 'You can share up to 20 icons a day. Try again tomorrow.';
  end if;
  return new;
end $$;
drop trigger if exists posts_limit on public.posts;
create trigger posts_limit before insert on public.posts for each row execute function public.limit_posts();

-- ───────────────────────── Reports ─────────────────────────
-- One report per person per post. 3 reports hide the post until an admin looks at it.
create table if not exists public.reports (
  post_id uuid not null references public.posts(id) on delete cascade,
  reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, reporter_id)
);
alter table public.reports enable row level security;
drop policy if exists "Report posts" on public.reports;
create policy "Report posts" on public.reports for insert to authenticated
  with check (reporter_id = auth.uid() and not public.is_banned());
drop policy if exists "See your own reports, or all as admin" on public.reports;
create policy "See your own reports, or all as admin" on public.reports for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin());
revoke insert, update, delete on public.reports from anon, authenticated;
grant select, insert on public.reports to authenticated;

create or replace function public.count_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.posts
     set report_count = (select count(*) from public.reports where post_id = new.post_id),
         hidden = hidden or (select count(*) from public.reports where post_id = new.post_id) >= 3
   where id = new.post_id;
  return new;
end $$;
drop trigger if exists reports_count on public.reports;
create trigger reports_count after insert on public.reports for each row execute function public.count_report();

-- ───────────────────────── Admin tools ─────────────────────────
-- Put a reported post back (clears its reports).
create or replace function public.admin_restore_post(post uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  delete from public.reports where post_id = post;
  update public.posts set hidden = false, report_count = 0 where id = post;
end $$;

-- Ban or unban an account. Banned accounts can't share or report, and their posts are hidden.
create or replace function public.admin_set_banned(target uuid, ban boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if target = auth.uid() then raise exception 'You can''t ban yourself'; end if;
  update public.profiles set banned = ban where id = target;
end $$;

revoke execute on function public.admin_restore_post(uuid) from public, anon;
revoke execute on function public.admin_set_banned(uuid, boolean) from public, anon;
grant execute on function public.admin_restore_post(uuid) to authenticated;
grant execute on function public.admin_set_banned(uuid, boolean) to authenticated;
grant execute on function public.username_available(text) to anon, authenticated;

-- ───────────────────────── Image storage ─────────────────────────
-- Public bucket for shared icons: PNG/WebP only, up to 1 MB each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('icons', 'icons', true, 1048576, array['image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/png', 'image/webp'];

drop policy if exists "Upload icons to your own folder" on storage.objects;
create policy "Upload icons to your own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'icons' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned());
drop policy if exists "Delete your own icon files, or any as admin" on storage.objects;
create policy "Delete your own icon files, or any as admin" on storage.objects for delete to authenticated
  using (bucket_id = 'icons' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ───────────────────────── Profile pictures ─────────────────────────

-- Each account can point at one picture in its own folder of the "avatars" storage bucket.
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles drop constraint if exists profiles_avatar_path_check;
alter table public.profiles add constraint profiles_avatar_path_check
  check (avatar_path is null or avatar_path like id::text || '/%');
-- People may change their display name and picture, nothing else.
revoke update on public.profiles from anon, authenticated;
grant update (display_name, avatar_path) on public.profiles to authenticated;

-- Public bucket for profile pictures: PNG/WebP/JPEG only, up to 512 KB each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 524288, array['image/png', 'image/webp', 'image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 524288, allowed_mime_types = array['image/png', 'image/webp', 'image/jpeg'];

drop policy if exists "Upload a picture to your own folder" on storage.objects;
create policy "Upload a picture to your own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned());
drop policy if exists "Delete your own pictures, or any as admin" on storage.objects;
create policy "Delete your own pictures, or any as admin" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- Admins can put someone's picture back to the grey monke.
create or replace function public.admin_clear_avatar(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles set avatar_path = null where id = target;
end $$;
revoke execute on function public.admin_clear_avatar(uuid) from public, anon;
grant execute on function public.admin_clear_avatar(uuid) to authenticated;

-- ───────────────────────── Bad word filter ─────────────────────────
-- Icon titles, usernames and display names with a banned word or phrase are refused before they're saved.
-- It catches common tricks (sh1t, $hit, f u c k, fuuuck) without blocking innocent words that just
-- contain a bad one (class, Scunthorpe). Running this also deletes already-posted icons with a bad title.
--
-- To add a word later:     insert into public.banned_words (word) values ('newword') on conflict do nothing;
-- To remove one:           delete from public.banned_words where word = 'oldword';
-- To add a phrase:         insert into public.banned_phrases (phrase) values ('two words') on conflict do nothing;
-- (Words are lowercase letters only. "anywhere = true" also catches the word hidden inside other text,
--  so only use it for words that never appear inside innocent ones.)

create table if not exists public.banned_words (
  word text primary key check (word ~ '^[a-z]+$'),
  anywhere boolean not null default false
);
alter table public.banned_words enable row level security;   -- no policies: the list isn't readable from the site
revoke all on public.banned_words from anon, authenticated;

insert into public.banned_words (word, anywhere) values
 ('fuck', true), ('fvck', true), ('phuck', true), ('phuk', false), ('fck', false),
 ('biatch', false), ('btch', false), ('azz', false), ('fuk', false), ('fucking', true), ('motherfucker', true), ('wtf', false), ('stfu', false),
 ('shit', false), ('bullshit', false), ('shite', false),
 ('ass', false), ('arse', false), ('asshole', false), ('arsehole', false), ('jackass', false), ('dumbass', false),
 ('bitch', false), ('bastard', false), ('dick', false), ('cock', false), ('prick', false), ('pussy', false),
 ('cunt', false), ('twat', false), ('wank', false), ('wanker', false), ('bellend', false), ('bollocks', false),
 ('piss', false), ('slut', false), ('whore', false), ('slag', false), ('hoe', false),
 ('porn', false), ('porno', false), ('sex', false), ('sexy', false), ('nude', false), ('naked', false),
 ('boob', false), ('tits', false), ('titty', false), ('penis', false), ('vagina', false), ('dildo', false), ('cum', false),
 ('horny', false), ('rape', false), ('rapist', false), ('pedo', false), ('paedo', false),
 ('nazi', false), ('hitler', false), ('kys', false), ('killyourself', true),
 ('nigger', true), ('nigga', true), ('faggot', true), ('fag', false), ('retard', false), ('retarded', false),
 ('tranny', false), ('spic', false), ('chink', false), ('kike', false), ('wetback', false), ('coon', false), ('paki', false)
on conflict (word) do nothing;

create table if not exists public.banned_phrases (
  phrase text primary key check (phrase ~ '^[a-z]+( [a-z]+)+$')   -- lowercase words separated by single spaces
);
alter table public.banned_phrases enable row level security;   -- not readable from the site
revoke all on public.banned_phrases from anon, authenticated;

-- Phrases that are only bad together: "beach" is fine, "you beach" isn't.
insert into public.banned_phrases (phrase) values
 ('you beach'), ('u beach'), ('ur beach'), ('ya beach'), ('yo beach'),
 ('you a beach'), ('u a beach'), ('ur a beach'), ('your a beach'), ('youre a beach'), ('you re a beach'), ('u r a beach'),
 ('son of a beach'), ('sons of beaches'), ('beach please'), ('shut up beach'), ('shutup beach'),
 ('stupid beach'), ('dumb beach'), ('ugly beach'), ('fat beach'), ('lil beach'), ('little beach you')
on conflict (phrase) do nothing;

-- true if the text has a banned word or phrase. Used by the rules below, and by the site to warn before posting.
create or replace function public.has_bad_words(t text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  n text;    -- lowercase, with look-alike symbols turned into letters
  sq text;   -- n with everything but letters removed and repeated letters squashed (catches "f u c k", "fuuuck")
  ws text;   -- the words of n, one space apart, with a space at each end (for phrases)
  wsq text;  -- ws with repeated letters squashed ("you beeeach")
  sfx constant text := '(s|es|ed|er|ers|ing|in|y|ty|head|heads|face|hole|holes)?$';
  pass int;
begin
  if t is null or btrim(t) = '' then return false; end if;
  -- Numbers and symbols can stand for more than one letter ("1" = i or l, "2" = s or z, "6" = g or b), so try two readings.
  for pass in 1..2 loop
    -- "!" and "|" only count as letters inside a word ("Sh!t"), not as punctuation at the end ("beach!").
    n := translate(regexp_replace(lower(t), '[!|]+(?![a-z0-9@$!|+(<€])', ' ', 'g'), '013457@$!|2689+(<€', case pass when 1 then 'oieastasiisgbgtcce' else 'oleastasllzbbgtcce' end);
    sq := regexp_replace(regexp_replace(n, '[^a-z]', '', 'g'), '(.)\1+', '\1', 'g');
    ws := ' ' || btrim(regexp_replace(n, '[^a-z]+', ' ', 'g')) || ' ';
    wsq := regexp_replace(ws, '(.)\1+', '\1', 'g');
    if exists (
        -- whole words (plus endings like -s, -ing, -head), also with repeated letters squashed for longer words
        select 1 from public.banned_words w, regexp_split_to_table(n, '[^a-z]+') tok
         where tok <> ''
           and (tok ~ ('^' || w.word || sfx)
                or (length(regexp_replace(w.word, '(.)\1+', '\1', 'g')) >= 4
                    and regexp_replace(tok, '(.)\1+', '\1', 'g') ~ ('^' || regexp_replace(w.word, '(.)\1+', '\1', 'g') || sfx))))
      or exists (
        -- the worst words, even when hidden inside other text or spaced out
        select 1 from public.banned_words w
         where w.anywhere and strpos(sq, regexp_replace(w.word, '(.)\1+', '\1', 'g')) > 0)
      or exists (
        -- phrases that are only bad together, like "you beach"
        select 1 from public.banned_phrases b
         where strpos(ws, ' ' || b.phrase || ' ') > 0
            or strpos(wsq, ' ' || regexp_replace(b.phrase, '(.)\1+', '\1', 'g') || ' ') > 0)
    then return true; end if;
  end loop;
  return false;
end $$;
revoke execute on function public.has_bad_words(text) from public;
grant execute on function public.has_bad_words(text) to anon, authenticated;

-- Refuse icon titles with bad words.
create or replace function public.check_post_words() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.has_bad_words(new.title) then
    raise exception 'That title has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists posts_bad_words on public.posts;
create trigger posts_bad_words before insert on public.posts for each row execute function public.check_post_words();

-- Refuse usernames and display names with bad words (this also stops sign-ups with them).
create or replace function public.check_profile_words() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.has_bad_words(new.username) or public.has_bad_words(new.display_name) then
    raise exception 'That name has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists profiles_bad_words on public.profiles;
create trigger profiles_bad_words before insert or update of username, display_name on public.profiles
  for each row execute function public.check_profile_words();

-- Clean up anything already posted with a bad title.
delete from public.posts where public.has_bad_words(title);

-- ───────────────────────── Emoji reactions ─────────────────────────
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

-- ───────────────────────── Comments ─────────────────────────
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
-- Replies: a comment can say which comment it answers. If that one is deleted, the reply stays.
alter table public.comments add column if not exists reply_to uuid references public.comments(id) on delete set null;
grant insert (post_id, body, reply_to) on public.comments to authenticated;
grant delete on public.comments to authenticated;

-- Bad words, length and spam checks. A reply must be to a comment on the same icon.
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
  if new.reply_to is not null and not exists (select 1 from public.comments where id = new.reply_to and post_id = new.post_id) then
    raise exception 'That comment isn''t there any more.';
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

-- ───────────────────────── Update notifications ─────────────────────────
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

-- ───────────────────────── Comment notifications ─────────────────────────
-- When someone comments on an icon, the icon's owner and everyone else who commented on it get a notification
-- (if they turned notifications on while signed in). Nobody is notified about their own comment.
-- A comment can only trigger its notifications once, right after it's posted, by the person who wrote it.
-- The list of devices to notify is only ever read by the sender function, never by the site.

alter table public.comments add column if not exists notified boolean not null default false;

-- Step 1 (as the commenter): "I just posted this comment, please notify people." Only works once, within 5 minutes.
create or replace function public.claim_comment_notification(p_comment uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  update public.comments set notified = true
   where id = p_comment and user_id = auth.uid() and not notified and created_at > now() - interval '5 minutes'
     and not public.is_banned()
  returning true into ok;
  return coalesce(ok, false);
end $$;

-- Step 2 (sender function only): which devices to notify, and what to say. Each person gets one notification: "replied to
-- you" beats "comment on your icon", which beats "comment on an icon you commented on". Never about your own comment.
create or replace function public.comment_push_targets(p_comment uuid)
returns table (endpoint text, p256dh text, auth_secret text, kind text, author_name text, post_title text, body text, post_id uuid)
language sql stable security definer set search_path = public as $$
  with c as (select * from public.comments where id = p_comment),
       p as (select posts.* from public.posts join c on posts.id = c.post_id),
       who as (
         select distinct on (uid) uid, kind from (
           select r.user_id as uid, 'reply'::text as kind, 1 as rank from public.comments r, c where r.id = c.reply_to and r.user_id <> c.user_id
           union all
           select p.user_id, 'owner', 2 from p, c where p.user_id <> c.user_id
           union all
           select cm.user_id, 'thread', 3 from public.comments cm, c where cm.post_id = c.post_id and cm.id <> c.id and cm.user_id <> c.user_id
         ) x order by uid, rank
       )
  select s.endpoint, s.p256dh, s.auth_secret, who.kind,
         (select display_name from public.profiles where id = c.user_id), coalesce(p.title, ''), c.body, c.post_id
    from who join public.push_subscriptions s on s.user_id = who.uid, c, p;
$$;

-- Sender function only: forget devices whose browser says they're gone.
create or replace function public.service_remove_push(p_endpoints text[]) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = any(p_endpoints);
$$;

revoke execute on function public.claim_comment_notification(uuid) from public, anon;
grant execute on function public.claim_comment_notification(uuid) to authenticated;
revoke execute on function public.comment_push_targets(uuid) from public, anon, authenticated;
revoke execute on function public.service_remove_push(text[]) from public, anon, authenticated;
grant execute on function public.comment_push_targets(uuid) to service_role;
grant execute on function public.service_remove_push(text[]) to service_role;

-- ───────────────────────── Remix ─────────────────────────
-- Icons shared to the gallery also save their design settings (colours, accessories, background and so on), so
-- other people can tap Remix to load that design into the editor. Name tags aren't saved. If an icon was made
-- by remixing another one, it remembers which, so the original creator gets the credit.

alter table public.posts add column if not exists design jsonb
  check (design is null or (jsonb_typeof(design) = 'object' and pg_column_size(design) < 4000));
alter table public.posts add column if not exists remix_of uuid references public.posts(id) on delete set null;
grant insert (image_path, title, design, remix_of) on public.posts to authenticated;

-- ───────────────────────── Profiles: descriptions and followers ─────────────────────────
-- Everyone can write a short description (up to 160 characters, through the bad word filter) and follow other
-- accounts. Follower counts are public. People can only follow and unfollow as themselves.

-- Descriptions
alter table public.profiles add column if not exists bio text check (bio is null or char_length(bio) <= 160);
revoke update on public.profiles from anon, authenticated;
grant update (display_name, avatar_path, bio) on public.profiles to authenticated;

-- The bad word filter now checks descriptions too.
create or replace function public.check_profile_words() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.has_bad_words(new.username) or public.has_bad_words(new.display_name) or public.has_bad_words(new.bio) then
    raise exception 'That has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  new.bio := nullif(btrim(new.bio), '');
  return new;
end $$;
drop trigger if exists profiles_bad_words on public.profiles;
create trigger profiles_bad_words before insert or update of username, display_name, bio on public.profiles
  for each row execute function public.check_profile_words();

-- Followers
create table if not exists public.follows (
  follower_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index if not exists follows_followee_idx on public.follows (followee_id);
alter table public.follows enable row level security;
drop policy if exists "Follows are public" on public.follows;
create policy "Follows are public" on public.follows for select using (true);
drop policy if exists "Follow as yourself" on public.follows;
create policy "Follow as yourself" on public.follows for insert to authenticated
  with check (follower_id = auth.uid() and not public.is_banned());
drop policy if exists "Unfollow as yourself" on public.follows;
create policy "Unfollow as yourself" on public.follows for delete to authenticated using (follower_id = auth.uid());
revoke all on public.follows from anon, authenticated;
grant select on public.follows to anon, authenticated;
grant insert (followee_id) on public.follows to authenticated;
grant delete on public.follows to authenticated;

-- Followers / following / icons counts for a profile.
create or replace function public.profile_stats(p_user uuid)
returns table (followers int, following int, icons int)
language sql stable security definer set search_path = public as $$
  select (select count(*)::int from public.follows where followee_id = p_user),
         (select count(*)::int from public.follows where follower_id = p_user),
         (select count(*)::int from public.posts where user_id = p_user and not hidden);
$$;
grant execute on function public.profile_stats(uuid) to anon, authenticated;

-- ───────────────────────── Likes and follower notifications ─────────────────────────
-- Likes: each signed-in person can like each icon once. Every icon keeps a like count, so the gallery can show the
-- most liked icons first.
-- Follower notifications: when someone follows you, you get a notification (if you turned notifications on while
-- signed in). Following and unfollowing someone over and over only notifies them once a day.

-- ───────── Likes ─────────
alter table public.posts add column if not exists like_count int not null default 0;
create index if not exists posts_likes_idx on public.posts (like_count desc, created_at desc);

create table if not exists public.likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.likes enable row level security;
drop policy if exists "Likes are public" on public.likes;
create policy "Likes are public" on public.likes for select using (true);
drop policy if exists "Like as yourself" on public.likes;
create policy "Like as yourself" on public.likes for insert to authenticated
  with check (user_id = auth.uid() and not public.is_banned()
              and exists (select 1 from public.posts p where p.id = post_id and not p.hidden));
drop policy if exists "Unlike as yourself" on public.likes;
create policy "Unlike as yourself" on public.likes for delete to authenticated using (user_id = auth.uid());
revoke all on public.likes from anon, authenticated;
grant select on public.likes to anon, authenticated;
grant insert (post_id) on public.likes to authenticated;
grant delete on public.likes to authenticated;

-- Keep each icon's like count up to date.
create or replace function public.count_likes() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid := coalesce(new.post_id, old.post_id);
begin
  update public.posts set like_count = (select count(*) from public.likes where post_id = pid) where id = pid;
  return null;
end $$;
drop trigger if exists likes_count on public.likes;
create trigger likes_count after insert or delete on public.likes for each row execute function public.count_likes();
-- (in case any likes already exist)
update public.posts p set like_count = (select count(*) from public.likes l where l.post_id = p.id);

-- ───────── Follower notifications ─────────
create table if not exists public.follow_notices (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (follower_id, followee_id)
);
alter table public.follow_notices enable row level security;   -- no policies: only used by the functions below
revoke all on public.follow_notices from anon, authenticated;

-- Step 1 (as the new follower): "I just followed this person, please tell them." Returns the follower's id,
-- or nothing if they don't really follow them, or were already announced in the last day.
create or replace function public.claim_follow_notification(p_followee uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or public.is_banned() then return null; end if;
  if not exists (select 1 from public.follows where follower_id = me and followee_id = p_followee
                 and created_at > now() - interval '5 minutes') then return null; end if;
  if exists (select 1 from public.follow_notices where follower_id = me and followee_id = p_followee
             and sent_at > now() - interval '1 day') then return null; end if;
  insert into public.follow_notices (follower_id, followee_id) values (me, p_followee)
  on conflict (follower_id, followee_id) do update set sent_at = now();
  return me;
end $$;

-- Step 2 (sender function only): the new follower's name, and the devices of the person they followed.
create or replace function public.follow_push_targets(p_follower uuid, p_followee uuid)
returns table (endpoint text, p256dh text, auth_secret text, follower_name text, follower_username text)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth_secret, f.display_name, f.username
    from public.push_subscriptions s, public.profiles f
   where s.user_id = p_followee and f.id = p_follower and p_follower <> p_followee;
$$;

revoke execute on function public.claim_follow_notification(uuid) from public, anon;
grant execute on function public.claim_follow_notification(uuid) to authenticated;
revoke execute on function public.follow_push_targets(uuid, uuid) from public, anon, authenticated;
grant execute on function public.follow_push_targets(uuid, uuid) to service_role;

-- ───────────────────────── Like notifications ─────────────────────────
-- When someone likes one of your icons, you get a notification (if you turned notifications on while signed in).
-- You're never notified about your own likes, and liking/unliking the same icon over and over only notifies once a day.

create table if not exists public.like_notices (
  liker_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (liker_id, post_id)
);
alter table public.like_notices enable row level security;   -- no policies: only used by the functions below
revoke all on public.like_notices from anon, authenticated;

-- Step 1 (as the person who liked): "I just liked this icon, please tell its owner." Returns the liker's id, or
-- nothing if they don't really like it, it's their own icon, or the owner was already told in the last day.
create or replace function public.claim_like_notification(p_post uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or public.is_banned() then return null; end if;
  if not exists (select 1 from public.likes l join public.posts p on p.id = l.post_id
                  where l.post_id = p_post and l.user_id = me and p.user_id <> me
                    and l.created_at > now() - interval '5 minutes') then return null; end if;
  if exists (select 1 from public.like_notices where liker_id = me and post_id = p_post
             and sent_at > now() - interval '1 day') then return null; end if;
  insert into public.like_notices (liker_id, post_id) values (me, p_post)
  on conflict (liker_id, post_id) do update set sent_at = now();
  return me;
end $$;

-- Step 2 (sender function only): the liker's name, the icon's title, and the owner's devices.
create or replace function public.like_push_targets(p_liker uuid, p_post uuid)
returns table (endpoint text, p256dh text, auth_secret text, liker_name text, post_title text)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth_secret, l.display_name, coalesce(p.title, '')
    from public.posts p
    join public.push_subscriptions s on s.user_id = p.user_id
    join public.profiles l on l.id = p_liker
   where p.id = p_post and p.user_id <> p_liker;
$$;

revoke execute on function public.claim_like_notification(uuid) from public, anon;
grant execute on function public.claim_like_notification(uuid) to authenticated;
revoke execute on function public.like_push_targets(uuid, uuid) from public, anon, authenticated;
grant execute on function public.like_push_targets(uuid, uuid) to service_role;

-- ───────────────────────── Live updates ─────────────────────────
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

-- ───────────────────────── Make yourself admin ─────────────────────────
-- After you've created your own account on the site, run this line once (with your username):
--   update public.profiles set is_admin = true where username = 'your_username';
