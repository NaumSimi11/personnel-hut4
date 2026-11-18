-- 0119: the internal job board is switched off in Phase 1 (board card C5, decision D8).
--
-- D8: no internal applications in Phase 1, so nothing should be published
-- to the internal board, not even by mistake. The channel is archived — the
-- job's channel panel lists live channels only — any live internal listing
-- is closed, and publishing to an archived channel is refused here, so no
-- door around the panel can do it either. The app hides the Internal jobs
-- page. Unarchiving the channel switches it all back on (Phase 2, card P7).

begin;

update public.channels set archived_at = now() where key = 'internal' and archived_at is null;
update public.job_channels set status = 'closed'
 where channel_key = 'internal' and status not in ('not_selected', 'closed');

create or replace function app.channel_must_be_on() returns trigger
language plpgsql set search_path = public as $$
declare v_label text;
begin
  if new.status in ('not_selected', 'closing', 'closed') then return new; end if;
  select label into v_label from public.channels where key = new.channel_key and archived_at is not null;
  if found then
    raise exception '% is switched off.', v_label using errcode = '23514';
  end if;
  return new;
end $$;

create trigger t2_channel_must_be_on before insert or update of status, channel_key on public.job_channels
  for each row execute function app.channel_must_be_on();

commit;
