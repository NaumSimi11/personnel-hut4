-- 0019_documents.sql
-- Documents (plan 026): the rows and visibility rules exist since 0004/0006;
-- this adds file facts, server-set provenance and versioning, company-level
-- categories, and the private bucket the files live in.

alter table public.documents
  add column original_name text,
  add column mime_type text,
  add column size_bytes int check (size_bytes is null or size_bytes >= 0),
  add column note text;
create unique index documents_storage_path_key on public.documents (storage_path);

insert into public.document_categories (key, label, person_scoped, sort_order) values
  ('registration', 'Registration & legal', false, 110),
  ('insurance', 'Insurance', false, 120),
  ('third_party_agreement', 'Third-party agreement', false, 130),
  ('company_other', 'Other company document', false, 190)
on conflict (key) do nothing;

-- ------------------------------------------------------------- provenance
-- The uploader is whoever is signed in, a person document belongs to a
-- company the person has employment with, categories match the scope, and
-- a new version supersedes (and archives) exactly one live document of the
-- same person and company.
create or replace function app.prepare_document() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_category record;
  v_old record;
begin
  new.uploaded_by := app.current_person_id();
  new.archived_at := null;
  select * into v_category from public.document_categories where key = new.category_key;
  if not found or v_category.archived_at is not null then
    raise exception 'Choose the document category.';
  end if;
  if new.person_id is null and v_category.person_scoped then
    raise exception 'That category is for a person''s documents; choose a company category.';
  end if;
  if new.person_id is not null and not v_category.person_scoped then
    raise exception 'That category is for company documents; choose a person category.';
  end if;
  if new.person_id is not null and not exists (
       select 1 from public.employment_periods ep
       where ep.person_id = new.person_id and ep.company_id = new.company_id) then
    raise exception 'This person has no employment in that company.';
  end if;
  if length(trim(coalesce(new.title, ''))) < 2 then
    raise exception 'Enter the document title.';
  end if;
  new.title := trim(new.title);

  if new.supersedes_id is not null then
    select * into v_old from public.documents where id = new.supersedes_id for update;
    if not found then
      raise exception 'The document this replaces was not found.';
    end if;
    if v_old.company_id <> new.company_id or v_old.person_id is distinct from new.person_id then
      raise exception 'A new version must belong to the same person and company.';
    end if;
    if v_old.archived_at is not null then
      raise exception 'That document is archived; a live document is needed to add a version.';
    end if;
    new.version := v_old.version + 1;
    update public.documents set archived_at = now() where id = v_old.id;
  else
    new.version := 1;
  end if;
  return new;
end $$;
create trigger prepare_document before insert on public.documents
  for each row execute function app.prepare_document();

-- Version, uploader and lineage are immutable once written.
create or replace function app.freeze_document_lineage() returns trigger
language plpgsql as $$
begin
  new.version := old.version;
  new.uploaded_by := old.uploaded_by;
  new.supersedes_id := old.supersedes_id;
  new.storage_path := old.storage_path;
  new.company_id := old.company_id;
  new.person_id := old.person_id;
  new.created_at := old.created_at;
  return new;
end $$;
create trigger freeze_document_lineage before update on public.documents
  for each row execute function app.freeze_document_lineage();

-- ------------------------------------------------------------- private bucket
-- Objects live at {company_id}/{person_id|company}/{document_id}.{ext}; the
-- first segment names the company for the write policies. Reads are gated by
-- the documents table itself: an object is readable only when a row the
-- viewer can see points to it — or when the viewer may upload in that
-- company, so an upload whose row was refused can be removed again (a
-- DELETE only reaches rows the SELECT policy exposes).
create or replace function app.document_object_company(object_name text) returns uuid
language sql stable as $$
  select case
    when split_part(object_name, '/', 1)
         ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    then split_part(object_name, '/', 1)::uuid
    else null
  end
$$;
grant execute on function app.document_object_company(text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('employee-documents', 'employee-documents', false, 20971520,
        array['application/pdf',
              'application/msword',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'image/png', 'image/jpeg'])
on conflict (id) do nothing;

create policy "employee documents: visible rows read" on storage.objects
  for select to authenticated
  using (bucket_id = 'employee-documents'
         and (exists (select 1 from public.documents d where d.storage_path = name)
              or app.has_capability(app.document_object_company(name), 'documents.upload')));
create policy "employee documents: uploaders write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'employee-documents'
              and app.has_capability(app.document_object_company(name), 'documents.upload'));
create policy "employee documents: uploaders delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'employee-documents'
         and app.has_capability(app.document_object_company(name), 'documents.upload'));
