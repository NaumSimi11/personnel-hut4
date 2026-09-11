-- 0004_operations.sql
-- HR operations: onboarding/offboarding plans and tasks, documents & policies,
-- equipment, IT requests, payroll preparation.

create table public.plan_phases (
  key text primary key,        -- before_start, day_one, week_one, month_one
  label text not null,
  sort_order int not null default 0
);

create table public.document_categories (
  key text primary key,        -- employment_agreement, amendment, onboarding_form, …
  label text not null,
  person_scoped boolean not null default true,
  sort_order int not null default 0,
  archived_at timestamptz
);

create table public.asset_types (
  key text primary key,        -- laptop, monitor, phone, accessory, software_license
  label text not null,
  is_physical boolean not null default true,
  archived_at timestamptz
);

-- ------------------------------------------------------------ task templates
-- Templates are copied into plans on assignment; editing a template never
-- rewrites active plans (product plan §3).
create table public.task_templates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id),   -- NULL = shared default
  kind text not null check (kind in ('onboarding','offboarding','employment_change')),
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (company_id, kind, name)
);
create trigger touch before update on public.task_templates
  for each row execute function app.touch_updated_at();

create table public.template_tasks (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.task_templates(id) on delete cascade,
  title text not null,
  description text,
  default_owner_role text not null default 'hr'
    check (default_owner_role in ('hr','it','manager','employee','finance')),
  phase_key text not null references public.plan_phases(key),
  due_offset_days int not null default 0,   -- relative to plan start date
  critical boolean not null default false,  -- required before start (readiness)
  requires_evidence boolean not null default false,
  sort_order int not null default 0
);

-- -------------------------------------------------------------------- plans
create table public.plans (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('onboarding','offboarding','employment_change')),
  person_id uuid not null references public.people(id),
  company_id uuid not null references public.companies(id),
  employment_period_id uuid references public.employment_periods(id),
  template_id uuid references public.task_templates(id),
  hr_owner_id uuid references public.people(id),
  start_date date not null,                 -- the date deadlines key off
  status text not null default 'in_progress' check (status in
    ('in_progress','completed','cancelled')),
  completed_at timestamptz,
  cancelled_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- avoid duplicate active plans of one kind per employment period
create unique index one_active_plan_per_period_kind
  on public.plans (employment_period_id, kind)
  where status = 'in_progress' and employment_period_id is not null;
create index plans_company_idx on public.plans (company_id);
create trigger touch before update on public.plans
  for each row execute function app.touch_updated_at();

-- Snapshot of template fields at assignment time (denormalized on purpose).
create table public.plan_tasks (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans(id) on delete cascade,
  template_task_id uuid references public.template_tasks(id),
  title text not null,
  description text,
  owner_id uuid references public.people(id),
  owner_role text not null default 'hr'
    check (owner_role in ('hr','it','manager','employee','finance')),
  phase_key text not null references public.plan_phases(key),
  due_date date,
  critical boolean not null default false,
  requires_evidence boolean not null default false,
  status text not null default 'open' check (status in ('open','done','blocked','skipped')),
  done_by uuid references public.people(id),
  done_at timestamptz,
  blocked_reason text,        -- required when blocked (app-enforced)
  skip_reason text,           -- required when skipped (app-enforced)
  evidence_document_id uuid,  -- FK added below once documents exists
  sort_order int not null default 0,
  updated_at timestamptz not null default now()
);
create index plan_tasks_plan_idx on public.plan_tasks (plan_id);
create trigger touch before update on public.plan_tasks
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------- documents
-- Employee files and company files; new versions supersede, never overwrite.
-- Binary content lives in Supabase Storage; storage_path points at it and the
-- bucket policy asks the same app.has_capability questions.
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  person_id uuid references public.people(id),      -- NULL = company document
  category_key text not null references public.document_categories(key),
  title text not null,
  storage_path text not null,
  version int not null default 1,
  supersedes_id uuid references public.documents(id),
  visibility text not null default 'person_and_hr' check (visibility in
    ('hr_only','person_and_hr','company_public')),
  uploaded_by uuid references public.people(id),
  archived_at timestamptz,
  created_at timestamptz not null default now()
);
create index documents_person_idx on public.documents (person_id);
create index documents_company_idx on public.documents (company_id);

alter table public.plan_tasks
  add constraint plan_tasks_evidence_fk
  foreign key (evidence_document_id) references public.documents(id);
alter table public.promotions
  add constraint promotions_creative_fk
  foreign key (creative_document_id) references public.documents(id);

create table public.document_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  person_id uuid not null references public.people(id),
  category_key text not null references public.document_categories(key),
  due_date date,
  reviewer_id uuid references public.people(id),
  status text not null default 'pending' check (status in
    ('pending','submitted','accepted','needs_correction','cancelled')),
  fulfilled_document_id uuid references public.documents(id),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger touch before update on public.document_requests
  for each row execute function app.touch_updated_at();

-- ----------------------------------------------------------------- policies
create table public.policies (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id),   -- NULL = holding-wide
  title text not null,
  storage_path text,
  version int not null default 1,
  status text not null default 'draft' check (status in ('draft','published','archived')),
  published_at timestamptz,
  published_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger touch before update on public.policies
  for each row execute function app.touch_updated_at();

-- Acknowledgements record exactly which version was acknowledged.
create table public.policy_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null references public.policies(id),
  person_id uuid not null references public.people(id),
  version int not null,
  acknowledged_at timestamptz not null default now(),
  unique (policy_id, person_id, version)
);

-- ------------------------------------------------------------------- assets
create table public.assets (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),  -- owning company
  asset_tag text not null,
  type_key text not null references public.asset_types(key),
  model text,
  serial_number text,
  condition text,
  status text not null default 'available' check (status in
    ('available','reserved','assigned','damaged','lost','retired')),
  location_id uuid references public.locations(id),
  note text,
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, asset_tag)
);
create trigger touch before update on public.assets
  for each row execute function app.touch_updated_at();

create table public.asset_assignments (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id),
  person_id uuid not null references public.people(id),
  reserved_at timestamptz,
  issued_at timestamptz,
  issued_by uuid references public.people(id),
  returned_at timestamptz,
  return_condition text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger touch before update on public.asset_assignments
  for each row execute function app.touch_updated_at();
-- one asset cannot have two concurrent assignees (product plan §5)
create unique index one_open_assignment_per_asset
  on public.asset_assignments (asset_id)
  where returned_at is null;
create index asset_assignments_person_idx on public.asset_assignments (person_id);

-- -------------------------------------------------------------- it_requests
-- Work status is independent of any notification email; completing the linked
-- onboarding task happens through plan_task_id, no duplicate checkbox.
-- Never store credentials or passwords in these rows.
create table public.it_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  person_id uuid not null references public.people(id),
  kind text not null default 'manual' check (kind in
    ('onboarding','role_change','departure','manual')),
  title text not null,
  requested_systems jsonb not null default '[]'::jsonb,
  due_at timestamptz,
  assignee_id uuid references public.people(id),
  status text not null default 'open' check (status in
    ('open','in_progress','blocked','done','cancelled')),
  blocked_reason text,
  plan_task_id uuid references public.plan_tasks(id),
  requested_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index it_requests_company_idx on public.it_requests (company_id);
create trigger touch before update on public.it_requests
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------- payroll (prep)
-- Preparation/export handoff only (payroll depth is an open decision).
-- Explicit company + period + currency; never silently combine currencies.
create table public.payroll_periods (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  period_start date not null,
  period_end date not null,
  currency char(3) not null,
  status text not null default 'draft' check (status in
    ('draft','in_review','approved','exported')),
  approved_by uuid references public.people(id),
  exported_at timestamptz,
  export_document_id uuid references public.documents(id),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, period_start, period_end),
  constraint valid_payroll_period check (period_end >= period_start)
);
create trigger touch before update on public.payroll_periods
  for each row execute function app.touch_updated_at();
