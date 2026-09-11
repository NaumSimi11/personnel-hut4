-- 0005_integrations_audit.sql
-- External connections (status only — secrets live in Supabase Vault, never
-- here), the read-only Zoho Projects mirror, the leave-system indicator,
-- workflow owners, admin-definable custom fields, and the audit log.

create table public.providers (
  key text primary key,          -- zoho_projects, leave_system, linkedin, indeed, careers
  label text not null,
  kind text not null check (kind in ('projects','leave','recruitment','publishing')),
  archived_at timestamptz
);

-- ------------------------------------------------------------- integrations
-- Per-company connection status (blueprint §5): a holding connection must say
-- exactly which external org/page it controls.
create table public.integrations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  provider_key text not null references public.providers(key),
  external_org_id text,
  authorized_by uuid references public.people(id),
  status text not null default 'not_connected' check (status in
    ('not_connected','authorization_required','connected','sync_issue','disconnected')),
  last_sync_at timestamptz,
  last_error text,
  config jsonb not null default '{}'::jsonb,   -- NON-secret settings only
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, provider_key)
);
create trigger touch before update on public.integrations
  for each row execute function app.touch_updated_at();

-- -------------------------------------------------- external projects mirror
-- Read-only facts synced from the project system (Zoho). No authenticated
-- write policies exist for these tables: only the sync service writes them.
create table public.external_projects (
  id uuid primary key default gen_random_uuid(),
  provider_key text not null references public.providers(key),
  external_id text not null,
  company_id uuid not null references public.companies(id),
  name text not null,
  status text,
  url text,
  raw jsonb not null default '{}'::jsonb,
  last_synced_at timestamptz not null default now(),
  unique (provider_key, external_id)
);
create index external_projects_company_idx on public.external_projects (company_id);

create table public.external_project_members (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.external_projects(id) on delete cascade,
  person_id uuid not null references public.people(id),
  external_ref text,
  role text,
  last_synced_at timestamptz not null default now(),
  unique (project_id, person_id)
);
create index external_project_members_person_idx
  on public.external_project_members (person_id);

-- ------------------------------------------------------- leave-system links
-- Read-only availability indicator (product plan §12): stale/failed sync is
-- shown as unavailable, never interpreted as "no absence".
create table public.leave_links (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null unique references public.people(id),
  provider_key text not null references public.providers(key),
  external_employee_id text not null,
  last_status text,
  last_synced_at timestamptz,
  sync_error text,
  updated_at timestamptz not null default now()
);
create trigger touch before update on public.leave_links
  for each row execute function app.touch_updated_at();

-- ----------------------------------------------------------- workflow owners
-- Approvals route to a named owner or configured role in the correct company;
-- if none is configured the UI shows Unassigned rather than skipping approval.
create table public.workflow_roles (
  key text primary key,          -- hiring_approver, offer_approver, marketing_reviewer, hr_owner, it_owner
  label text not null
);

create table public.workflow_owners (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  role_key text not null references public.workflow_roles(key),
  person_id uuid references public.people(id),   -- NULL renders as Unassigned
  updated_at timestamptz not null default now(),
  unique (company_id, role_key)
);
create trigger touch before update on public.workflow_owners
  for each row execute function app.touch_updated_at();

-- ------------------------------------------------------ custom field schema
-- Admins define extra fields per entity; values live in that entity's
-- `custom` jsonb. Adding a field is an INSERT here — no DDL, no migration.
create table public.custom_field_definitions (
  id uuid primary key default gen_random_uuid(),
  entity text not null check (entity in
    ('people','employment_periods','jobs','hiring_requests','applications',
     'candidates','assets')),
  company_id uuid references public.companies(id),  -- NULL = all companies
  key text not null,
  label text not null,
  field_type text not null check (field_type in
    ('text','number','date','boolean','select','multi_select')),
  required boolean not null default false,
  options jsonb not null default '[]'::jsonb,       -- for select types
  sort_order int not null default 0,
  archived_at timestamptz,
  unique nulls not distinct (entity, company_id, key)
);

-- -------------------------------------------------------------- activity log
-- Who changed what, when, before/after (blueprint §3.6). Rows are written only
-- by the audit trigger (SECURITY DEFINER) — no direct client writes.
create table public.activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  company_id uuid,
  actor_person_id uuid,
  actor_user_id uuid,
  entity_type text not null,
  entity_id text,
  action text not null,          -- INSERT | UPDATE | DELETE
  before jsonb,
  after jsonb
);
create index activity_log_company_idx on public.activity_log (company_id, at desc);
create index activity_log_entity_idx on public.activity_log (entity_type, entity_id);

create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb := to_jsonb(coalesce(new, old));
begin
  insert into public.activity_log
    (company_id, actor_person_id, actor_user_id, entity_type, entity_id, action, before, after)
  values (
    (rec->>'company_id')::uuid,
    app.current_person_id(),
    auth.uid(),
    tg_table_name,
    rec->>'id',
    tg_op,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

-- Audited tables. Deliberately NOT person_private_details (data minimization:
-- PII must not be duplicated into the log) — audit it app-side by field name
-- only if required later.
create trigger audit after insert or update or delete on public.access_grants
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.grant_capabilities
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.platform_admins
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.employment_periods
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.compensation_records
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.hiring_requests
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.jobs
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.job_channels
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.applications
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.offers
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.promotions
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.documents
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.payroll_periods
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.integrations
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.workflow_owners
  for each row execute function app.audit();
