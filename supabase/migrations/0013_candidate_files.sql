-- 0013_candidate_files.sql
-- Candidate review depth, part one (plan 018a): the candidate's material in
-- one place. Files (CV, cover letter, portfolio) live in a PRIVATE bucket and
-- are described by application_files rows; answers to the job's screening
-- questions live on the application. Everything follows the application's
-- company through candidates.view (read) and candidates.review (write).

-- ------------------------------------------------------- application_files
create table public.application_files (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  company_id uuid not null references public.companies(id),  -- derived, never client-trusted
  kind text not null default 'cv' check (kind in ('cv', 'cover_letter', 'portfolio', 'other')),
  storage_path text not null unique,
  original_name text not null,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  uploaded_by uuid references public.people(id),
  -- Plain-text extraction for plan 020's summaries; null until produced.
  extracted_text text,
  created_at timestamptz not null default now()
);
create index application_files_application_idx on public.application_files (application_id);

-- Same pattern as offers: the company comes from the application row, so a
-- forged company_id can never widen who may read the file.
create or replace function app.sync_application_file_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select company_id into strict new.company_id
    from public.applications where id = new.application_id;
  return new;
end $$;
create trigger sync_company before insert or update of application_id on public.application_files
  for each row execute function app.sync_application_file_company();

create trigger audit after insert or update or delete on public.application_files
  for each row execute function app.audit();

alter table public.application_files enable row level security;
create policy sel on public.application_files for select to authenticated
  using (app.has_capability(company_id, 'candidates.view'));
create policy ins on public.application_files for insert to authenticated
  with check (exists (select 1 from public.applications a
                      where a.id = application_id
                        and app.has_capability(a.company_id, 'candidates.review')));
create policy del on public.application_files for delete to authenticated
  using (app.has_capability(company_id, 'candidates.review'));

grant select, insert, delete on public.application_files to authenticated;
grant all on public.application_files to service_role;

-- ---------------------------------------------------------- screening answers
-- [{ question_id, answer }] against jobs.screening_questions.
alter table public.applications
  add column screening_answers jsonb not null default '[]'::jsonb,
  add constraint applications_screening_answers_is_array
    check (jsonb_typeof(screening_answers) = 'array');

-- ------------------------------------------------------------- private bucket
-- Objects live at {application_id}/{file_id}.{ext}; the first path segment
-- is the application, which is how the policies find the company.
create or replace function app.application_company(application uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.applications where id = application
$$;
grant execute on function app.application_company(uuid) to authenticated;

-- A name that is not application-keyed belongs to no company (rather than
-- raising on the cast and taking every reviewer's read down with it).
create or replace function app.candidate_object_company(object_name text) returns uuid
language sql stable security definer set search_path = public as $$
  select case
    when split_part(object_name, '/', 1)
         ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    then app.application_company(split_part(object_name, '/', 1)::uuid)
    else null
  end
$$;
grant execute on function app.candidate_object_company(text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('candidate-files', 'candidate-files', false, 10485760,
        array['application/pdf',
              'application/msword',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'text/plain', 'image/png', 'image/jpeg'])
on conflict (id) do nothing;

create policy "candidate files: reviewers read" on storage.objects
  for select to authenticated
  using (bucket_id = 'candidate-files'
         and app.has_capability(app.candidate_object_company(name), 'candidates.view'));
create policy "candidate files: reviewers upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'candidate-files'
              and app.has_capability(app.candidate_object_company(name), 'candidates.review'));
create policy "candidate files: reviewers delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'candidate-files'
         and app.has_capability(app.candidate_object_company(name), 'candidates.review'));
