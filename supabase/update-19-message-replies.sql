-- Monke Icon Maker: Orangemonke can reply to "Talk to Orangemonke" messages.
-- Run once in Supabase: SQL Editor > new blank snippet > paste all of this > Run. Safe to run again.
-- (Needs update-18 (Talk to Orangemonke) first. New projects: setup.sql has it all.)
--
-- Only admins can reply. The person who sent the message sees the reply under it and in their notifications.

alter table public.fan_messages add column if not exists reply text;
alter table public.fan_messages add column if not exists replied_at timestamptz;
alter table public.fan_messages drop constraint if exists fan_messages_reply_check;
alter table public.fan_messages add constraint fan_messages_reply_check check (reply is null or char_length(btrim(reply)) between 1 and 500);

-- Reply (or change your reply). An empty reply removes it.
create or replace function public.reply_fan_message(p_id uuid, p_reply text) returns boolean
language plpgsql security definer set search_path = public as $$
declare r text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if r is not null and public.has_bad_words(r) then
    raise exception 'That reply has a word that isn''t allowed.' using errcode = 'check_violation';
  end if;
  update public.fan_messages set reply = r, replied_at = case when r is null then null else now() end where id = p_id;
  return found;
end $$;
revoke execute on function public.reply_fan_message(uuid, text) from public, anon;
grant execute on function public.reply_fan_message(uuid, text) to authenticated;
