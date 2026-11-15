-- Monke Icon Maker: bad word filter, round 3 — banned phrases.
-- Blocks phrases that are only bad together, like "you beach", while "beach" on its own stays fine.
-- Also removes anything already posted that the filter now catches.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-3 and update-4 to have been run first. New projects: setup.sql has it all.)
--
-- To add a phrase later:   insert into public.banned_phrases (phrase) values ('two words') on conflict do nothing;
-- To remove one:           delete from public.banned_phrases where phrase = 'two words';

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

-- Clean up anything already posted that the filter now catches.
delete from public.posts where public.has_bad_words(title);
