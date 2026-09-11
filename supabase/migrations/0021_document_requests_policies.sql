-- 0021_document_requests_policies.sql
-- Document requests with self-service submission, and policies with
-- versioned acknowledgements (plan 028). Tables and their read/write reach
-- exist since 0004/0006; this adds provenance, the state machines, the
-- self-service window on documents/storage, and the policies bucket.

-- ------------------------------------------------------- document requests
create or replace function app.prepare_document_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_category record;
begin
  new.status := 'pending';
  new.fulfilled_document_id := null;
  new.reviewer_id := coalesce(app.current_person_id(), new.reviewer_id);
  select * into v_category from public.document_categories where key = new.category_key;
  if not found or v_category.archived_at is not null or not v_category.person_scoped then
    raise exception 'Choose a person document category.';
  end if;
  if not exists (select 1 from public.employment_periods ep
                 where ep.person_id = new.person_id and ep.company_id = new.company_id) then
    raise exception 'This person has no employment in that company.';
  end if;
  new.note := nullif(trim(coalesce(new.note, '')), '');
  return new;
end $$;
create trigger prepare_document_request before insert on public.document_requests
  for each row execute function app.prepare_document_request();

-- Status and fulfilment move only through the functions below.
create or replace function app.freeze_document_request() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null and current_setting('app.request_transition', true) is distinct from 'on' then
    new.status := old.status;
    new.fulfilled_document_id := old.fulfilled_document_id;
  end if;
  new.company_id := old.company_id;
  new.person_id := old.person_id;
  new.category_key := old.category_key;
  new.created_at := old.created_at;
  return new;
end $$;
create trigger freeze_document_request before update on public.document_requests
  for each row execute function app.freeze_document_request();

-- Is there an open request for this person / company / category? Used by the
-- self-service window on documents and storage.
create or replace function app.has_open_document_request(person uuid, company uuid, category text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.document_requests r
                 where r.person_id = person and r.company_id = company and r.category_key = category
                   and r.status in ('pending', 'needs_correction'))
$$;
grant execute on function app.has_open_document_request(uuid, uuid, text) to authenticated;

create or replace function app.self_document_window(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select split_part(object_name, '/', 2) = app.current_person_id()::text
     and exists (select 1 from public.document_requests r
                 where r.person_id = app.current_person_id()
                   and r.company_id = app.document_object_company(object_name)
                   and r.status in ('pending', 'needs_correction'))
$$;
grant execute on function app.self_document_window(text) to authenticated;

create policy ins_self on public.documents for insert to authenticated
  with check (app.is_self(person_id)
              and app.has_open_document_request(person_id, company_id, category_key));
create policy "employee documents: requested self upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'employee-documents' and app.self_document_window(name));

-- A self-service upload is always visible to the person and HR, never HR-only
-- and never company-wide; the uploader cannot pick.
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
  if new.person_id is not null and new.uploaded_by is not distinct from new.person_id
     and not app.has_capability(new.company_id, 'documents.upload') then
    new.visibility := 'person_and_hr';
  end if;

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

create or replace function public.submit_requested_document(p_request_id uuid, p_document_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_request record;
  v_doc record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_request from public.document_requests where id = p_request_id for update;
  if not found or v_request.person_id <> v_me then
    raise exception 'Request not found.';
  end if;
  if v_request.status not in ('pending', 'needs_correction') then
    raise exception 'This request is not waiting for a document.';
  end if;
  select * into v_doc from public.documents where id = p_document_id;
  if not found or v_doc.person_id is distinct from v_me or v_doc.company_id <> v_request.company_id
     or v_doc.category_key <> v_request.category_key or v_doc.archived_at is not null then
    raise exception 'Upload a document of the requested kind first.';
  end if;
  perform set_config('app.request_transition', 'on', true);
  update public.document_requests
    set status = 'submitted', fulfilled_document_id = p_document_id
    where id = p_request_id;
  perform set_config('app.request_transition', 'off', true);
  return jsonb_build_object('status', 'submitted');
end $$;

create or replace function public.review_document_request(p_request_id uuid, p_decision text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_request record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_request from public.document_requests where id = p_request_id for update;
  if not found then
    raise exception 'Request not found.';
  end if;
  if not app.has_capability(v_request.company_id, 'documents.request') then
    raise exception 'Reviewing document requests needs documents.request in this company.' using errcode = '42501';
  end if;
  if p_decision = 'cancelled' then
    if v_request.status in ('accepted', 'cancelled') then
      raise exception 'This request is already closed.';
    end if;
  elsif p_decision in ('accepted', 'needs_correction') then
    if v_request.status <> 'submitted' then
      raise exception 'Only a submitted document can be accepted or sent back.';
    end if;
  else
    raise exception 'Unknown decision: %', p_decision;
  end if;
  perform set_config('app.request_transition', 'on', true);
  update public.document_requests
    set status = p_decision, reviewer_id = v_me,
        note = case when nullif(trim(coalesce(p_note, '')), '') is null then note
                    else concat_ws(' — ', note, trim(p_note)) end
    where id = p_request_id;
  perform set_config('app.request_transition', 'off', true);
  return jsonb_build_object('status', p_decision);
end $$;

revoke all on function public.submit_requested_document(uuid, uuid) from public, anon;
revoke all on function public.review_document_request(uuid, text, text) from public, anon;
grant execute on function public.submit_requested_document(uuid, uuid) to authenticated, service_role;
grant execute on function public.review_document_request(uuid, text, text) to authenticated, service_role;

-- ------------------------------------------------------------------ policies
alter table public.policies
  add column original_name text,
  add column mime_type text,
  add column summary text;

create or replace function app.can_publish_policy(company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when company is null then app.is_admin() else app.has_capability(company, 'policies.publish') end
$$;
grant execute on function app.can_publish_policy(uuid) to authenticated;

-- Status, version and publication facts move only through the functions.
create or replace function app.prepare_policy() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.version := 1;
    new.published_at := null;
    new.published_by := null;
  elsif current_setting('app.policy_transition', true) is distinct from 'on' then
    new.status := old.status;
    new.version := old.version;
    new.published_at := old.published_at;
    new.published_by := old.published_by;
    new.company_id := old.company_id;
  end if;
  if length(trim(coalesce(new.title, ''))) < 2 then
    raise exception 'Enter the policy title.';
  end if;
  new.title := trim(new.title);
  return new;
end $$;
create trigger prepare_policy before insert or update on public.policies
  for each row execute function app.prepare_policy();

create or replace function public.publish_policy(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_policy record;
  v_version int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_policy from public.policies where id = p_policy_id for update;
  if not found then
    raise exception 'Policy not found.';
  end if;
  if not app.can_publish_policy(v_policy.company_id) then
    raise exception 'Publishing needs policies.publish in this company (holding-wide: platform admin).' using errcode = '42501';
  end if;
  if v_policy.status = 'archived' then
    raise exception 'An archived policy cannot be published; create a new one.';
  end if;
  if v_policy.storage_path is null then
    raise exception 'Attach the policy document before publishing.';
  end if;
  -- A re-publish is a new version: earlier acknowledgements no longer count.
  v_version := case when v_policy.status = 'published' then v_policy.version + 1 else v_policy.version end;
  perform set_config('app.policy_transition', 'on', true);
  update public.policies
    set status = 'published', version = v_version, published_at = now(), published_by = v_me
    where id = p_policy_id;
  perform set_config('app.policy_transition', 'off', true);
  return jsonb_build_object('status', 'published', 'version', v_version);
end $$;

create or replace function public.archive_policy(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_policy record;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_policy from public.policies where id = p_policy_id for update;
  if not found then
    raise exception 'Policy not found.';
  end if;
  if not app.can_publish_policy(v_policy.company_id) then
    raise exception 'Archiving needs policies.publish in this company (holding-wide: platform admin).' using errcode = '42501';
  end if;
  perform set_config('app.policy_transition', 'on', true);
  update public.policies set status = 'archived' where id = p_policy_id;
  perform set_config('app.policy_transition', 'off', true);
  return jsonb_build_object('status', 'archived');
end $$;

-- The person acknowledges the version they can currently read.
create or replace function public.acknowledge_policy(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_policy record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_policy from public.policies where id = p_policy_id;
  if not found or v_policy.status <> 'published'
     or not (v_policy.company_id is null or app.in_company(v_policy.company_id)) then
    raise exception 'Policy not found.';
  end if;
  insert into public.policy_acknowledgements (policy_id, person_id, version)
    values (p_policy_id, v_me, v_policy.version)
    on conflict (policy_id, person_id, version) do nothing;
  return jsonb_build_object('version', v_policy.version);
end $$;

revoke all on function public.publish_policy(uuid) from public, anon;
revoke all on function public.archive_policy(uuid) from public, anon;
revoke all on function public.acknowledge_policy(uuid) from public, anon;
grant execute on function public.publish_policy(uuid) to authenticated, service_role;
grant execute on function public.archive_policy(uuid) to authenticated, service_role;
grant execute on function public.acknowledge_policy(uuid) to authenticated, service_role;

-- Holding-wide policies have no company to scope the read policy on; the
-- 0006 read policy already handles company_id null. Publishers see drafts.
drop policy if exists sel on public.policies;
create policy sel on public.policies for select to authenticated
  using ((status = 'published' and (company_id is null or app.in_company(company_id)))
         or app.can_publish_policy(company_id));
drop policy if exists write on public.policies;
create policy write on public.policies for all to authenticated
  using (app.can_publish_policy(company_id))
  with check (app.can_publish_policy(company_id));

-- Who acknowledged: the person, and anyone who may publish in that scope or
-- holds documents.view in the company.
drop policy if exists sel on public.policy_acknowledgements;
create policy sel on public.policy_acknowledgements for select to authenticated
  using (app.is_self(person_id) or exists (
    select 1 from public.policies po where po.id = policy_id
      and (app.can_publish_policy(po.company_id)
           or (po.company_id is not null and app.has_capability(po.company_id, 'documents.view')))));

-- Private bucket at {company_id|holding}/{policy_id}.{ext}.
create or replace function app.policy_object_scope(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when split_part(object_name, '/', 1) = 'holding' then app.is_admin()
    when app.document_object_company(object_name) is not null
      then app.has_capability(app.document_object_company(object_name), 'policies.publish')
    else false
  end
$$;
grant execute on function app.policy_object_scope(text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('policies', 'policies', false, 20971520,
        array['application/pdf',
              'application/msword',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do nothing;

create policy "policies: visible rows read" on storage.objects
  for select to authenticated
  using (bucket_id = 'policies'
         and (exists (select 1 from public.policies p where p.storage_path = name)
              or app.policy_object_scope(name)));
create policy "policies: publishers write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'policies' and app.policy_object_scope(name));
create policy "policies: publishers delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'policies' and app.policy_object_scope(name));

-- ------------------------------------------------------------ review fixes
-- Acknowledgements are recorded only by acknowledge_policy (the 0006 direct
-- insert allowed a person to pre-acknowledge a future version).
drop policy if exists write on public.policy_acknowledgements;

-- The self-service window is the caller's own; nobody probes other people's
-- open requests through it.
create or replace function app.has_open_document_request(person uuid, company uuid, category text) returns boolean
language sql stable security definer set search_path = public as $$
  select person = app.current_person_id()
     and exists (select 1 from public.document_requests r
                 where r.person_id = person and r.company_id = company and r.category_key = category
                   and r.status in ('pending', 'needs_correction'))
$$;

-- A self-service upload whose row was refused can be taken back by its owner.
create policy "employee documents: requested self delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'employee-documents' and app.self_document_window(name));

-- A new version keeps the category (so a self-service correction cannot
-- archive an unrelated document of the person's).
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
  if new.person_id is not null and new.uploaded_by is not distinct from new.person_id
     and not app.has_capability(new.company_id, 'documents.upload') then
    new.visibility := 'person_and_hr';
  end if;

  if new.supersedes_id is not null then
    select * into v_old from public.documents where id = new.supersedes_id for update;
    if not found then
      raise exception 'The document this replaces was not found.';
    end if;
    if v_old.company_id <> new.company_id or v_old.person_id is distinct from new.person_id
       or v_old.category_key <> new.category_key then
      raise exception 'A new version must belong to the same person, company and category.';
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

-- A published policy's file is what people acknowledged: it changes only
-- together with the version, through publish_policy.
create or replace function app.prepare_policy() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.version := 1;
    new.published_at := null;
    new.published_by := null;
  elsif current_setting('app.policy_transition', true) is distinct from 'on' then
    new.status := old.status;
    new.version := old.version;
    new.published_at := old.published_at;
    new.published_by := old.published_by;
    new.company_id := old.company_id;
    if old.status = 'published' and new.storage_path is distinct from old.storage_path then
      raise exception 'Publish a new version to change the file of a published policy.';
    end if;
  end if;
  if length(trim(coalesce(new.title, ''))) < 2 then
    raise exception 'Enter the policy title.';
  end if;
  new.title := trim(new.title);
  return new;
end $$;

drop function if exists public.publish_policy(uuid);
create or replace function public.publish_policy(
  p_policy_id uuid,
  p_storage_path text default null,
  p_original_name text default null,
  p_mime_type text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_policy record;
  v_version int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_policy from public.policies where id = p_policy_id for update;
  if not found then
    raise exception 'Policy not found.';
  end if;
  if not app.can_publish_policy(v_policy.company_id) then
    raise exception 'Publishing needs policies.publish in this company (holding-wide: platform admin).' using errcode = '42501';
  end if;
  if v_policy.status = 'archived' then
    raise exception 'An archived policy cannot be published; create a new one.';
  end if;
  if v_policy.status = 'published' and p_storage_path is null then
    raise exception 'Attach the new file to publish a new version.';
  end if;
  if coalesce(p_storage_path, v_policy.storage_path) is null then
    raise exception 'Attach the policy document before publishing.';
  end if;
  -- A re-publish is a new version: earlier acknowledgements no longer count.
  v_version := case when v_policy.status = 'published' then v_policy.version + 1 else v_policy.version end;
  perform set_config('app.policy_transition', 'on', true);
  update public.policies
    set status = 'published', version = v_version, published_at = now(), published_by = v_me,
        storage_path = coalesce(p_storage_path, storage_path),
        original_name = coalesce(p_original_name, original_name),
        mime_type = coalesce(p_mime_type, mime_type)
    where id = p_policy_id;
  perform set_config('app.policy_transition', 'off', true);
  return jsonb_build_object('status', 'published', 'version', v_version);
end $$;
revoke all on function public.publish_policy(uuid, text, text, text) from public, anon;
grant execute on function public.publish_policy(uuid, text, text, text) to authenticated, service_role;
