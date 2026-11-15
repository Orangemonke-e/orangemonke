-- Monke Icon Maker: bad word filter, round 2.
-- Teaches the filter more number and symbol swaps (2h1t, 6itch, b!+ch ...) and removes anything already
-- posted that it now catches. Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run.
-- Safe to run again. (Needs update-3-bad-words.sql to have been run first. New projects: setup.sql has it all.)

-- A few more spellings.
insert into public.banned_words (word, anywhere) values
 ('phuck', true), ('phuk', false), ('biatch', false), ('btch', false), ('azz', false)
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
  -- Numbers and symbols can stand for more than one letter ("1" = i or l, "2" = s or z, "6" = g or b), so try two readings.
  for pass in 1..2 loop
    n := translate(lower(t), '013457@$!|2689+(<€', case pass when 1 then 'oieastasilsgbgtcce' else 'oleastasllzbbgtcce' end);
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

-- Clean up anything already posted that the filter now catches.
delete from public.posts where public.has_bad_words(title);
