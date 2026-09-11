-- 0001_foundation.sql
-- Personnel HR system: org structure, people, employment history, compensation.
-- Design rules (see docs/data-model.md):
--   * Business vocabularies (departments, types, categories) are LOOKUP TABLES:
--     extending them is an INSERT, not a migration.
--   * Code-coupled state machines are CHECK constraints (a new state needs app
--     logic anyway, so a migration is honest there).
--   * Person identity is separate from employment periods (transfers/rehires
--     preserve history) and from user accounts (an employee record alone is
--     not a login).
--   * Every entity HR may want extra fields on carries `custom jsonb`,
--     validated app-side against custom_field_definitions (0005).

create extension if not exists citext;
create extension if not exists btree_gist;

create schema if not exists app;

create or replace function app.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------- companies
create table public.companies (
  id uuid primary key default gen_random_uuid(),
  parent_company_id uuid references public.companies(id),
  kind text not null default 'company' check (kind in ('holding','company')),
  name text not null,
  short_code text not null unique,
  brand jsonb not null default '{}'::jsonb,
  -- shared-defaults-with-override home: notification contacts, workflow
  -- defaults, branding, onboarding requirements (blueprint §2)
  settings jsonb not null default '{}'::jsonb,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger touch before update on public.companies
  for each row execute function app.touch_updated_at();

-- ------------------------------------------------- shared/override lookups
-- company_id NULL = shared holding default; a row with company_id overrides
-- or extends for that company only.
create table public.departments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id),
  name text not null,
  archived_at timestamptz,
  unique nulls not distinct (company_id, name)
);

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id),
  name text not null,
  country_code char(2),
  archived_at timestamptz,
  unique nulls not distinct (company_id, name)
);

create table public.employment_types (
  key text primary key,            -- e.g. full_time, part_time, contractor
  label text not null,
  -- contractors may need different required fields (product plan §2)
  required_fields jsonb not null default '[]'::jsonb,
  sort_order int not null default 0,
  archived_at timestamptz
);

create table public.pay_bases (
  key text primary key,            -- annual, monthly, hourly, daily
  label text not null,
  sort_order int not null default 0
);

create table public.employment_statuses (
  key text primary key,            -- draft, pre_start, active, former
  label text not null,
  -- drives "does this period make the person a member of the company"
  -- (app.in_company); new statuses declare it instead of code hardcoding it
  counts_as_employed boolean not null default true,
  sort_order int not null default 0
);

-- ------------------------------------------------------------------ people
-- Person identity. user_id links to a Supabase auth account when one exists.
create table public.people (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  full_name text not null,
  preferred_name text,
  work_email citext,
  personal_email citext,          -- allowed before work email exists
  phone text,
  avatar_url text,
  custom jsonb not null default '{}'::jsonb,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index people_work_email_idx on public.people (work_email);
create trigger touch before update on public.people
  for each row execute function app.touch_updated_at();

-- Restricted personal fields live in their own table so the `personal.view`
-- capability maps to row security instead of per-column exceptions.
create table public.person_private_details (
  person_id uuid primary key references public.people(id) on delete cascade,
  birth_date date,
  address jsonb,
  emergency_contacts jsonb not null default '[]'::jsonb,
  national_id_hint text            -- last digits only; never the full value
    check (national_id_hint is null or length(national_id_hint) <= 8),
  notes text,
  custom jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create trigger touch before update on public.person_private_details
  for each row execute function app.touch_updated_at();

-- ------------------------------------------------------ employment_periods
-- One row per employment period. Transfers/rehires add rows; they never
-- overwrite history. Non-draft periods cannot overlap for the same person
-- (one employing company per person at a time — product plan §"Scale").
create table public.employment_periods (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id),
  company_id uuid not null references public.companies(id),
  job_title text not null,
  department_id uuid references public.departments(id),
  location_id uuid references public.locations(id),
  employment_type_key text references public.employment_types(key),
  manager_id uuid references public.people(id),
  status text not null default 'draft' references public.employment_statuses(key),
  start_date date not null,
  end_date date,
  last_working_date date,
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint valid_period check (end_date is null or end_date >= start_date),
  constraint no_overlapping_employment exclude using gist (
    person_id with =,
    daterange(start_date, coalesce(end_date, 'infinity'::date), '[]') with &&
  ) where (status <> 'draft')
);
create index employment_periods_company_idx on public.employment_periods (company_id);
create index employment_periods_person_idx on public.employment_periods (person_id);
create trigger touch before update on public.employment_periods
  for each row execute function app.touch_updated_at();

-- The departure reason is restricted detail ("restricted reason", product plan
-- §7); it lives in its own table so ordinary people.view holders never see it.
create table public.employment_departure_details (
  employment_period_id uuid primary key
    references public.employment_periods(id) on delete cascade,
  reason text,
  recorded_by uuid references public.people(id),
  recorded_at timestamptz not null default now()
);

-- ---------------------------------------------------- compensation_records
-- Dated, currency-explicit records; approved records cannot overlap for the
-- same employment period ("prevent ambiguous overlapping changes").
create table public.compensation_records (
  id uuid primary key default gen_random_uuid(),
  employment_period_id uuid not null references public.employment_periods(id),
  amount numeric(12,2) not null check (amount >= 0),
  currency char(3) not null,
  pay_basis_key text not null references public.pay_bases(key),
  effective_date date not null,
  end_date date,
  status text not null default 'proposed'
    check (status in ('proposed','approved','rejected','superseded')),
  proposed_by uuid references public.people(id),
  approved_by uuid references public.people(id),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint valid_comp_period check (end_date is null or end_date >= effective_date),
  constraint no_overlapping_compensation exclude using gist (
    employment_period_id with =,
    daterange(effective_date, coalesce(end_date, 'infinity'::date), '[]') with &&
  ) where (status = 'approved')
);
create index compensation_period_idx on public.compensation_records (employment_period_id);
create trigger touch before update on public.compensation_records
  for each row execute function app.touch_updated_at();
