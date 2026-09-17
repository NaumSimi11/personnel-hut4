-- 0064_handover_paperwork.sql
-- Tie a handover to the form it produced, so "we are waiting on the signed
-- copy" is a thing the app can say rather than a thing somebody remembers.
--
-- The app makes a PDF, the person prints it, signs it on paper and uploads the
-- scan back as version 2 of the same document. Until now nothing noticed if
-- that never happened: the handover read as finished in the app while the only
-- copy anybody could produce in an argument was unsigned.
--
-- The link is recovered from the queue row's dedupe key, which already carries
-- the handover id, rather than threading a new argument through
-- queue_generated_document and every one of its callers.

create or replace function app.link_handover_document() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_handover uuid;
begin
  if new.document_id is null or new.document_id is not distinct from old.document_id then
    return new;
  end if;
  v_handover := nullif(substring(new.dedupe_key from 'handover:([0-9a-f-]{36})'), '')::uuid;
  if v_handover is not null then
    update public.asset_handovers set document_id = new.document_id where id = v_handover;
  end if;
  return new;
end $$;

drop trigger if exists link_handover_document on public.generated_documents;
create trigger link_handover_document after update on public.generated_documents
  for each row execute function app.link_handover_document();

-- Anything already generated before this trigger existed.
update public.asset_handovers h
   set document_id = g.document_id
  from public.generated_documents g
 where g.document_id is not null
   and h.document_id is null
   and g.dedupe_key like '%handover:' || h.id::text || '%';

comment on column public.asset_handovers.document_id is
  'The form this handover produced. Still at version 1 means nobody has uploaded the signed scan.';
