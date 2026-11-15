-- Monke Icon Maker: bad word filter.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (New projects don't need this: setup.sql already includes it.)
--
-- Icon titles, usernames and display names with a banned word are refused before they're saved.
-- It catches common tricks (sh1t, $hit, f u c k, fuuuck) without blocking innocent words that just
-- contain a bad one (class, Scunthorpe). Running this also deletes already-posted icons with a bad title.
--
-- To add a word later:     insert into public.banned_words (word) values ('newword') on conflict do nothing;
-- To remove one:           delete from public.banned_words where word = 'oldword';
-- (Words are lowercase letters only. "anywhere = true" also catches the word hidden inside other text,
--  so only use it for words that never appear inside innocent ones.)

create table if not exists public.banned_words (
  word text primary key check (word ~ '^[a-z]+$'),
  anywhere boolean not null default false
);
alter table public.banned_words enable row level security;   -- no policies: the list isn't readable from the site
revoke all on public.banned_words from anon, authenticated;

insert into public.banned_words (word, anywhere) values
 ('fuck', true), ('fvck', true), ('fck', false), ('fuk', false), ('fucking', true), ('motherfucker', true), ('wtf', false), ('stfu', false),
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

-- true if the text has a banned word. Used by the rules below, and by the site to warn before posting.
create or replace function public.has_bad_words(t text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  n text;   -- lowercase, with look-alike symbols turned into letters
  sq text;  -- n with everything but letters removed and repeated letters squashed (catches "f u c k", "fuuuck")
  sfx constant text := '(s|es|ed|er|ers|ing|in|y|ty|head|heads|face|hole|holes)?$';
  pass int;
begin
  if t is null or btrim(t) = '' then return false; end if;
  -- "1" and "|" can stand for i or l, so try both readings.
  for pass in 1..2 loop
    n := translate(lower(t), '013457@$!|', case pass when 1 then 'oieastasil' else 'oleastasll' end);
    sq := regexp_replace(regexp_replace(n, '[^a-z]', '', 'g'), '(.)\1+', '\1', 'g');
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
