-- 0003_recruitment.sql
-- The connected hiring workspace (blueprint §4): request → approval → job →
-- channels → promotion → applications → offer → hire handoff.
-- State lists come from the blueprint; states are independent per entity
-- ("a job can be live on the careers site while one external board rejects it").

-- Application stages are business-extensible ("any additional stage must have
-- an operational purpose") — a lookup table, not a CHECK.
create table public.application_stages (
  key text primary key,      -- new, screening, interview, offer, hired, rejected, withdrawn
  label text not null,
  sort_order int not null default 0,
  is_terminal boolean not null default false
);

-- Publishing destinations (careers page, LinkedIn, Indeed, manual boards…).
create table public.channels (
  key text primary key,
  label text not null,
  kind text not null default 'job_board' check (kind in ('careers','job_board','social','manual')),
  archived_at timestamptz
);

-- ---------------------------------------------------------- hiring_requests
create table public.hiring_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  title text not null,
  reason text,
  headcount int not null default 1 check (headcount > 0),
  budget jsonb,                        -- {min, max, currency} — optional
  target_start_date date,
  hiring_manager_id uuid references public.people(id),
  requested_by uuid references public.people(id),
  status text not null default 'draft' check (status in
    ('draft','submitted','changes_requested','approved','rejected','cancelled')),
  change_reason text,
  decided_by uuid references public.people(id),
  decided_at timestamptz,
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index hiring_requests_company_idx on public.hiring_requests (company_id);
create trigger touch before update on public.hiring_requests
  for each row execute function app.touch_updated_at();

-- --------------------------------------------------------------------- jobs
create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  hiring_request_id uuid references public.hiring_requests(id),
  title text not null,
  description text,
  screening_questions jsonb not null default '[]'::jsonb,
  description_revision int not null default 1,  -- bumped on edit; channels track what they published
  status text not null default 'draft' check (status in
    ('draft','ready','open','on_hold','filled','closed')),
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index jobs_company_idx on public.jobs (company_id);
create trigger touch before update on public.jobs
  for each row execute function app.touch_updated_at();

-- ------------------------------------------------------------- job_channels
-- Per-destination status/link/error; provider confirmation, not the publish
-- click, determines live/closed (blueprint §4/§5).
create table public.job_channels (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  channel_key text not null references public.channels(key),
  status text not null default 'not_selected' check (status in
    ('not_selected','ready','queued','submitted','live','action_required',
     'failed','closing','closed')),
  external_job_id text,
  publication_url text,
  published_revision int,              -- jobs.description_revision it carries
  last_error text,
  published_by uuid references public.people(id),
  verified_by uuid references public.people(id),   -- manual-publication pattern
  updated_at timestamptz not null default now(),
  unique (job_id, channel_key)
);
create trigger touch before update on public.job_channels
  for each row execute function app.touch_updated_at();

-- --------------------------------------------------------------- candidates
-- Recruitment identity, separate from people; matching must never silently
-- merge records or leak another company's history (blueprint §5).
create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  email citext,
  phone text,
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger touch before update on public.candidates
  for each row execute function app.touch_updated_at();

-- ------------------------------------------------------------- applications
create table public.applications (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id),
  company_id uuid not null references public.companies(id), -- denormalized for RLS/routing
  candidate_id uuid not null references public.candidates(id),
  stage_key text not null default 'new' references public.application_stages(key),
  owner_id uuid references public.people(id),      -- who acts next
  next_action text,
  next_action_due date,
  source_channel_key text references public.channels(key),
  source_provider text,                            -- e.g. 'linkedin'
  provider_ref text,                               -- provider's application id
  received_at timestamptz not null default now(),
  withdrawn_reason text,
  rejected_reason text,
  -- exactly one employee may ever result from one application (idempotent hire)
  employment_period_id uuid unique references public.employment_periods(id),
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- provider retries must not duplicate an application (blueprint §5)
create unique index applications_provider_dedupe
  on public.applications (job_id, source_provider, provider_ref)
  where provider_ref is not null;
create index applications_job_idx on public.applications (job_id);
create index applications_company_idx on public.applications (company_id);
create trigger touch before update on public.applications
  for each row execute function app.touch_updated_at();

-- Stage history, notes, interview feedback — dated and attributable.
create table public.application_events (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  kind text not null check (kind in ('stage_change','note','interview_feedback')),
  from_stage_key text references public.application_stages(key),
  to_stage_key text references public.application_stages(key),
  body text,
  actor_id uuid references public.people(id),
  created_at timestamptz not null default now()
);
create index application_events_app_idx on public.application_events (application_id);

-- ------------------------------------------------------------------- offers
create table public.offers (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id),
  company_id uuid not null references public.companies(id),
  terms jsonb not null default '{}'::jsonb,        -- compensation, start date, type
  status text not null default 'draft' check (status in
    ('draft','in_approval','approved','extended','accepted','declined','withdrawn')),
  approved_by uuid references public.people(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- one live offer per application; superseded ones stay as history
create unique index one_open_offer_per_application
  on public.offers (application_id)
  where status not in ('declined','withdrawn');
create trigger touch before update on public.offers
  for each row execute function app.touch_updated_at();

-- --------------------------------------------------------------- promotions
-- Marketing collaboration (blueprint §6). Marketing works from `brief`
-- (approved public info snapshot) — never from jobs/applications directly.
create table public.promotions (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id),
  company_id uuid not null references public.companies(id),
  channel_key text not null default 'linkedin' references public.channels(key),
  brief jsonb not null default '{}'::jsonb,        -- public job brief snapshot
  copy text,
  creative_document_id uuid,                       -- FK added in 0004 (documents)
  status text not null default 'requested' check (status in
    ('requested','draft','in_review','changes_requested','approved',
     'scheduled','published','failed','cancelled')),
  publication_url text,
  requested_by uuid references public.people(id),
  reviewed_by uuid references public.people(id),
  published_by uuid references public.people(id),
  deadline date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (job_id, channel_key)
);
create trigger touch before update on public.promotions
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------- server-derived company scope
-- The denormalized company_id columns exist for cheap RLS checks but are NEVER
-- client-trusted: BEFORE triggers derive them from the parent row (SECURITY
-- DEFINER so the lookup works even when the actor cannot read the parent —
-- the RLS WITH CHECK then evaluates against the TRUE company and rejects
-- cross-company forgeries).
create or replace function app.sync_application_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select company_id into strict new.company_id from public.jobs where id = new.job_id;
  return new;
end $$;
create trigger t1_sync_company before insert or update on public.applications
  for each row execute function app.sync_application_company();

create or replace function app.sync_offer_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select company_id into strict new.company_id
    from public.applications where id = new.application_id;
  return new;
end $$;
create trigger t1_sync_company before insert or update on public.offers
  for each row execute function app.sync_offer_company();

create or replace function app.sync_promotion_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select company_id into strict new.company_id from public.jobs where id = new.job_id;
  return new;
end $$;
create trigger t1_sync_company before insert or update on public.promotions
  for each row execute function app.sync_promotion_company();

-- A job linked to a hiring request must belong to the same company.
create or replace function app.check_job_request_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.hiring_request_id is not null and (
    select company_id from public.hiring_requests where id = new.hiring_request_id
  ) is distinct from new.company_id then
    raise exception 'Job company must match its hiring request company';
  end if;
  return new;
end $$;
create trigger t1_check_request_company before insert or update on public.jobs
  for each row execute function app.check_job_request_company();

-- --------------------------------------------------------- transition gates
-- RLS decides who may touch a table; these gates decide which STATUS
-- transitions a signed-in user may perform: approving needs the approve
-- capability, publishing needs the publish capability, and requesters never
-- decide their own request (blueprint §3 default). Service paths — sync jobs
-- and trusted RPCs running without a user JWT (auth.uid() is null) — bypass.
create or replace function app.gate_hiring_request_transitions() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then prev := old.status; end if;
  if new.status in ('approved','rejected') and new.status is distinct from prev then
    if not app.has_capability(new.company_id, 'jobs.approve') then
      raise exception 'Deciding a hiring request requires jobs.approve'
        using errcode = '42501';
    end if;
    if new.requested_by is not distinct from app.current_person_id() then
      raise exception 'Requesters cannot decide their own hiring request'
        using errcode = '42501';
    end if;
    new.decided_by := app.current_person_id();
    new.decided_at := now();
  end if;
  return new;
end $$;
create trigger t2_gate_transitions before insert or update on public.hiring_requests
  for each row execute function app.gate_hiring_request_transitions();

create or replace function app.gate_offer_transitions() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then prev := old.status; end if;
  if new.status in ('approved','extended') and new.status is distinct from prev then
    if not app.has_capability(new.company_id, 'offer.approve') then
      raise exception 'Approving or extending an offer requires offer.approve'
        using errcode = '42501';
    end if;
    if new.status = 'approved' then
      new.approved_by := app.current_person_id();
    end if;
  end if;
  return new;
end $$;
create trigger t2_gate_transitions before insert or update on public.offers
  for each row execute function app.gate_offer_transitions();

create or replace function app.gate_promotion_transitions() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then prev := old.status; end if;
  if new.status = 'approved' and new.status is distinct from prev then
    if not app.has_capability(new.company_id, 'marketing.approve') then
      raise exception 'Approving promotional content requires marketing.approve'
        using errcode = '42501';
    end if;
    new.reviewed_by := app.current_person_id();
  end if;
  if new.status in ('scheduled','published') and new.status is distinct from prev then
    if not app.has_capability(new.company_id, 'marketing.publish') then
      raise exception 'Publishing promotional content requires marketing.publish'
        using errcode = '42501';
    end if;
    new.published_by := app.current_person_id();
  end if;
  return new;
end $$;
create trigger t2_gate_transitions before insert or update on public.promotions
  for each row execute function app.gate_promotion_transitions();
