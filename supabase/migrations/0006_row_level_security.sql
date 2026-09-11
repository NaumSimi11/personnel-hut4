-- 0006_row_level_security.sql
-- Default deny everywhere. Every table gets RLS enabled; policies ask
-- app.has_capability(company, cap) — the same question for tables, exports,
-- counts, and direct URLs (blueprint §3 permission semantics).
-- Pattern per table: one SELECT policy (read reach) + one FOR ALL policy
-- (write reach; also implies read for writers). service_role bypasses RLS.

-- ------------------------------------------------ additional secured helpers
create or replace function app.can_view_person(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_self(p) or app.is_admin() or exists (
    select 1 from public.employment_periods ep
    where ep.person_id = p and app.has_capability(ep.company_id, 'people.view'))
$$;

create or replace function app.has_capability_anywhere(cap text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or exists (
    select 1 from public.access_grants g
    join public.grant_capabilities gc on gc.grant_id = g.id
    where g.person_id = app.current_person_id() and gc.capability_key = cap)
$$;

create or replace function app.in_company(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin()
    or exists (select 1 from public.employment_periods ep
               join public.employment_statuses es on es.key = ep.status
               where ep.company_id = c and ep.person_id = app.current_person_id()
                 and es.counts_as_employed)
    or exists (select 1 from public.access_grants g
               where g.company_id = c and g.person_id = app.current_person_id())
$$;

-- Editing a person is scoped to companies where that person actually has an
-- employment record; a brand-new person (no periods yet) can be managed by
-- anyone holding employment.edit somewhere, so the add-employee flow works.
create or replace function app.can_edit_person(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin()
    or exists (select 1 from public.employment_periods ep
               where ep.person_id = p
                 and app.has_capability(ep.company_id, 'employment.edit'))
    or (not exists (select 1 from public.employment_periods ep where ep.person_id = p)
        and app.has_capability_anywhere('employment.edit'))
$$;

create or replace function app.can_view_compensation(period uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.employment_periods ep
    where ep.id = period
      and (ep.person_id = app.current_person_id()
           or app.has_capability(ep.company_id, 'salary.view')))
$$;

create or replace function app.can_write_compensation(period uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.employment_periods ep
    where ep.id = period
      and (app.has_capability(ep.company_id, 'salary.propose')
           or app.has_capability(ep.company_id, 'salary.approve')))
$$;

-- Candidate visibility is company-scoped through the applications that exist;
-- only a candidate with NO applications yet (a record mid-creation, affiliated
-- with no company) falls back to holding candidates.review anywhere.
create or replace function app.can_view_candidate(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin()
    or exists (select 1 from public.applications a
               where a.candidate_id = c
                 and app.has_capability(a.company_id, 'candidates.view'))
    or (not exists (select 1 from public.applications a where a.candidate_id = c)
        and app.has_capability_anywhere('candidates.review'))
$$;

create or replace function app.can_edit_candidate(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin()
    or exists (select 1 from public.applications a
               where a.candidate_id = c
                 and app.has_capability(a.company_id, 'candidates.review'))
    or (not exists (select 1 from public.applications a where a.candidate_id = c)
        and app.has_capability_anywhere('candidates.review'))
$$;

-- Project-mirror helpers: external_projects and external_project_members need
-- to look at each other; doing that inside their policies recurses. SECURITY
-- DEFINER breaks the cycle.
create or replace function app.is_project_member(project uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.external_project_members m
    where m.project_id = project and m.person_id = app.current_person_id())
$$;

create or replace function app.project_company(project uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.external_projects where id = project
$$;

grant execute on function
  app.can_view_person(uuid), app.can_edit_person(uuid),
  app.has_capability_anywhere(text), app.in_company(uuid),
  app.can_view_compensation(uuid), app.can_write_compensation(uuid),
  app.can_view_candidate(uuid), app.can_edit_candidate(uuid),
  app.is_project_member(uuid), app.project_company(uuid)
to authenticated;

-- --------------------------------------------------- reference/config tables
-- Readable by any signed-in user; writable by platform admins only.
do $$
declare t text;
begin
  foreach t in array array[
    'companies','departments','locations','employment_types','pay_bases',
    'employment_statuses','application_stages','channels','plan_phases',
    'document_categories','asset_types','providers','workflow_roles',
    'capabilities','capability_dependencies','permission_presets',
    'preset_capabilities','custom_field_definitions','workflow_owners']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy read_all on public.%I for select to authenticated using (true)', t);
    execute format(
      'create policy admin_write on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

-- ------------------------------------------------------------------- people
alter table public.people enable row level security;
create policy sel on public.people for select to authenticated
  using (app.can_view_person(id));
create policy ins on public.people for insert to authenticated
  with check (app.is_admin() or app.has_capability_anywhere('employment.edit'));
create policy upd on public.people for update to authenticated
  using (app.can_edit_person(id)) with check (app.can_edit_person(id));
create policy del on public.people for delete to authenticated
  using (app.is_admin());

alter table public.person_private_details enable row level security;
create policy sel on public.person_private_details for select to authenticated
  using (app.is_self(person_id) or exists (
    select 1 from public.employment_periods ep
    where ep.person_id = person_private_details.person_id
      and app.has_capability(ep.company_id, 'personal.view')));
create policy write on public.person_private_details for all to authenticated
  using (app.is_self(person_id) or exists (
    select 1 from public.employment_periods ep
    where ep.person_id = person_private_details.person_id
      and app.has_capability(ep.company_id, 'personal.view')))
  with check (app.is_self(person_id) or exists (
    select 1 from public.employment_periods ep
    where ep.person_id = person_private_details.person_id
      and app.has_capability(ep.company_id, 'personal.view')));

alter table public.employment_periods enable row level security;
create policy sel on public.employment_periods for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'people.view'));
create policy write on public.employment_periods for all to authenticated
  using (app.has_capability(company_id, 'employment.edit')
         or app.has_capability(company_id, 'departure.start'))
  with check (app.has_capability(company_id, 'employment.edit')
              or app.has_capability(company_id, 'departure.start'));

-- Departure reasons: restricted to offboarding/private-details capability
-- holders — deliberately NOT people.view, and not the person themself.
alter table public.employment_departure_details enable row level security;
create policy sel on public.employment_departure_details for select to authenticated
  using (exists (select 1 from public.employment_periods ep
                 where ep.id = employment_period_id
                   and (app.has_capability(ep.company_id, 'departure.start')
                        or app.has_capability(ep.company_id, 'personal.view'))));
create policy write on public.employment_departure_details for all to authenticated
  using (exists (select 1 from public.employment_periods ep
                 where ep.id = employment_period_id
                   and app.has_capability(ep.company_id, 'departure.start')))
  with check (exists (select 1 from public.employment_periods ep
                      where ep.id = employment_period_id
                        and app.has_capability(ep.company_id, 'departure.start')));

alter table public.compensation_records enable row level security;
create policy sel on public.compensation_records for select to authenticated
  using (app.can_view_compensation(employment_period_id));
create policy write on public.compensation_records for all to authenticated
  using (app.can_write_compensation(employment_period_id))
  with check (app.can_write_compensation(employment_period_id));

-- ----------------------------------------------------------- access control
alter table public.access_grants enable row level security;
create policy sel on public.access_grants for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'access.manage'));
create policy write on public.access_grants for all to authenticated
  using (app.has_capability(company_id, 'access.manage'))
  with check (app.has_capability(company_id, 'access.manage'));

alter table public.grant_capabilities enable row level security;
create policy sel on public.grant_capabilities for select to authenticated
  using (exists (select 1 from public.access_grants g
                 where g.id = grant_id
                   and (app.is_self(g.person_id)
                        or app.has_capability(g.company_id, 'access.manage'))));
create policy write on public.grant_capabilities for all to authenticated
  using (exists (select 1 from public.access_grants g
                 where g.id = grant_id
                   and app.has_capability(g.company_id, 'access.manage')))
  with check (exists (select 1 from public.access_grants g
                      where g.id = grant_id
                        and app.has_capability(g.company_id, 'access.manage')));

alter table public.platform_admins enable row level security;
create policy sel on public.platform_admins for select to authenticated
  using (app.is_admin());
create policy write on public.platform_admins for all to authenticated
  using (app.is_admin()) with check (app.is_admin());

-- -------------------------------------------------------------- recruitment
alter table public.hiring_requests enable row level security;
create policy sel on public.hiring_requests for select to authenticated
  using (app.has_capability(company_id, 'jobs.view'));
create policy write on public.hiring_requests for all to authenticated
  using (app.has_capability(company_id, 'jobs.request')
         or app.has_capability(company_id, 'jobs.edit')
         or app.has_capability(company_id, 'jobs.approve'))
  with check (app.has_capability(company_id, 'jobs.request')
              or app.has_capability(company_id, 'jobs.edit')
              or app.has_capability(company_id, 'jobs.approve'));

alter table public.jobs enable row level security;
create policy sel on public.jobs for select to authenticated
  using (app.has_capability(company_id, 'jobs.view'));
create policy write on public.jobs for all to authenticated
  using (app.has_capability(company_id, 'jobs.edit'))
  with check (app.has_capability(company_id, 'jobs.edit'));

alter table public.job_channels enable row level security;
create policy sel on public.job_channels for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id
                 and app.has_capability(j.company_id, 'jobs.view')));
create policy write on public.job_channels for all to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id
                 and app.has_capability(j.company_id, 'jobs.publish')))
  with check (exists (select 1 from public.jobs j where j.id = job_id
                      and app.has_capability(j.company_id, 'jobs.publish')));

alter table public.candidates enable row level security;
create policy sel on public.candidates for select to authenticated
  using (app.can_view_candidate(id));
create policy write on public.candidates for all to authenticated
  using (app.can_edit_candidate(id))
  with check (app.can_edit_candidate(id));

alter table public.applications enable row level security;
create policy sel on public.applications for select to authenticated
  using (app.has_capability(company_id, 'candidates.view'));
create policy write on public.applications for all to authenticated
  using (app.has_capability(company_id, 'candidates.review'))
  with check (app.has_capability(company_id, 'candidates.review'));

alter table public.application_events enable row level security;
create policy sel on public.application_events for select to authenticated
  using (exists (select 1 from public.applications a where a.id = application_id
                 and app.has_capability(a.company_id, 'candidates.view')));
create policy write on public.application_events for all to authenticated
  using (exists (select 1 from public.applications a where a.id = application_id
                 and app.has_capability(a.company_id, 'candidates.review')))
  with check (exists (select 1 from public.applications a where a.id = application_id
                      and app.has_capability(a.company_id, 'candidates.review')));

alter table public.offers enable row level security;
create policy sel on public.offers for select to authenticated
  using (app.has_capability(company_id, 'candidates.view'));
create policy write on public.offers for all to authenticated
  using (app.has_capability(company_id, 'candidates.review')
         or app.has_capability(company_id, 'offer.approve'))
  with check (app.has_capability(company_id, 'candidates.review')
              or app.has_capability(company_id, 'offer.approve'));

alter table public.promotions enable row level security;
create policy sel on public.promotions for select to authenticated
  using (app.has_capability(company_id, 'marketing.view')
         or app.has_capability(company_id, 'jobs.view'));
create policy write on public.promotions for all to authenticated
  using (app.has_capability(company_id, 'marketing.draft')
         or app.has_capability(company_id, 'marketing.approve')
         or app.has_capability(company_id, 'marketing.publish')
         or app.has_capability(company_id, 'jobs.edit'))
  with check (app.has_capability(company_id, 'marketing.draft')
              or app.has_capability(company_id, 'marketing.approve')
              or app.has_capability(company_id, 'marketing.publish')
              or app.has_capability(company_id, 'jobs.edit'));

-- --------------------------------------------------------------- operations
alter table public.task_templates enable row level security;
create policy sel on public.task_templates for select to authenticated using (true);
create policy write on public.task_templates for all to authenticated
  using (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'tasks.assign')))
  with check (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'tasks.assign')));

alter table public.template_tasks enable row level security;
create policy sel on public.template_tasks for select to authenticated using (true);
create policy write on public.template_tasks for all to authenticated
  using (exists (select 1 from public.task_templates tt where tt.id = template_id
                 and (app.is_admin() or (tt.company_id is not null
                      and app.has_capability(tt.company_id, 'tasks.assign')))))
  with check (exists (select 1 from public.task_templates tt where tt.id = template_id
                      and (app.is_admin() or (tt.company_id is not null
                           and app.has_capability(tt.company_id, 'tasks.assign')))));

alter table public.plans enable row level security;
create policy sel on public.plans for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'tasks.view'));
create policy write on public.plans for all to authenticated
  using (app.has_capability(company_id, 'tasks.assign'))
  with check (app.has_capability(company_id, 'tasks.assign'));

alter table public.plan_tasks enable row level security;
create policy sel on public.plan_tasks for select to authenticated
  using (app.is_self(owner_id) or exists (
    select 1 from public.plans p where p.id = plan_id
      and (app.is_self(p.person_id) or app.has_capability(p.company_id, 'tasks.view'))));
create policy write on public.plan_tasks for all to authenticated
  using (app.is_self(owner_id) or exists (
    select 1 from public.plans p where p.id = plan_id
      and (app.has_capability(p.company_id, 'tasks.assign')
           or app.has_capability(p.company_id, 'tasks.complete'))))
  with check (app.is_self(owner_id) or exists (
    select 1 from public.plans p where p.id = plan_id
      and (app.has_capability(p.company_id, 'tasks.assign')
           or app.has_capability(p.company_id, 'tasks.complete'))));

alter table public.documents enable row level security;
create policy sel on public.documents for select to authenticated
  using (app.has_capability(company_id, 'documents.view')
         or (app.is_self(person_id) and visibility <> 'hr_only')
         or (visibility = 'company_public' and app.in_company(company_id)));
create policy write on public.documents for all to authenticated
  using (app.has_capability(company_id, 'documents.upload'))
  with check (app.has_capability(company_id, 'documents.upload'));

alter table public.document_requests enable row level security;
create policy sel on public.document_requests for select to authenticated
  using (app.is_self(person_id)
         or app.has_capability(company_id, 'documents.view')
         or app.has_capability(company_id, 'documents.request'));
create policy write on public.document_requests for all to authenticated
  using (app.has_capability(company_id, 'documents.request'))
  with check (app.has_capability(company_id, 'documents.request'));

alter table public.policies enable row level security;
create policy sel on public.policies for select to authenticated
  using ((status = 'published' and (company_id is null or app.in_company(company_id)))
         or (company_id is not null and app.has_capability(company_id, 'policies.publish'))
         or app.is_admin());
create policy write on public.policies for all to authenticated
  using (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'policies.publish')))
  with check (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'policies.publish')));

alter table public.policy_acknowledgements enable row level security;
create policy sel on public.policy_acknowledgements for select to authenticated
  using (app.is_self(person_id) or exists (
    select 1 from public.policies po where po.id = policy_id
      and (app.is_admin() or (po.company_id is not null
           and app.has_capability(po.company_id, 'documents.view')))));
create policy write on public.policy_acknowledgements for insert to authenticated
  with check (app.is_self(person_id));   -- you acknowledge only for yourself

alter table public.assets enable row level security;
create policy sel on public.assets for select to authenticated
  using (app.has_capability(company_id, 'it.view'));
create policy write on public.assets for all to authenticated
  using (app.has_capability(company_id, 'it.assign'))
  with check (app.has_capability(company_id, 'it.assign'));

alter table public.asset_assignments enable row level security;
create policy sel on public.asset_assignments for select to authenticated
  using (app.is_self(person_id) or exists (
    select 1 from public.assets a where a.id = asset_id
      and app.has_capability(a.company_id, 'it.view')));
create policy write on public.asset_assignments for all to authenticated
  using (exists (select 1 from public.assets a where a.id = asset_id
                 and (app.has_capability(a.company_id, 'it.assign')
                      or app.has_capability(a.company_id, 'it.complete'))))
  with check (exists (select 1 from public.assets a where a.id = asset_id
                      and (app.has_capability(a.company_id, 'it.assign')
                           or app.has_capability(a.company_id, 'it.complete'))));

alter table public.it_requests enable row level security;
create policy sel on public.it_requests for select to authenticated
  using (app.is_self(person_id) or app.is_self(requested_by)
         or app.has_capability(company_id, 'it.view'));
create policy write on public.it_requests for all to authenticated
  using (app.has_capability(company_id, 'it.assign')
         or app.has_capability(company_id, 'it.complete')
         or app.has_capability(company_id, 'tasks.assign'))
  with check (app.has_capability(company_id, 'it.assign')
              or app.has_capability(company_id, 'it.complete')
              or app.has_capability(company_id, 'tasks.assign'));

alter table public.payroll_periods enable row level security;
create policy sel on public.payroll_periods for select to authenticated
  using (app.has_capability(company_id, 'payroll.summary'));
create policy write on public.payroll_periods for all to authenticated
  using (app.has_capability(company_id, 'payroll.individual')
         or app.has_capability(company_id, 'payroll.approve')
         or app.has_capability(company_id, 'payroll.export'))
  with check (app.has_capability(company_id, 'payroll.individual')
              or app.has_capability(company_id, 'payroll.approve')
              or app.has_capability(company_id, 'payroll.export'));

-- --------------------------------------------------- integrations & mirrors
alter table public.integrations enable row level security;
create policy sel on public.integrations for select to authenticated
  using (app.has_capability(company_id, 'integration.view'));
create policy write on public.integrations for all to authenticated
  using (app.has_capability(company_id, 'integration.manage'))
  with check (app.has_capability(company_id, 'integration.manage'));

-- Read-only mirrors: SELECT policies only. No authenticated write policy
-- exists, so only service_role (the sync job) can write them.
alter table public.external_projects enable row level security;
create policy sel on public.external_projects for select to authenticated
  using (app.has_capability(company_id, 'projects.view')
         or app.is_project_member(id));

alter table public.external_project_members enable row level security;
create policy sel on public.external_project_members for select to authenticated
  using (app.is_self(person_id)
         or app.has_capability(app.project_company(project_id), 'projects.view'));

alter table public.leave_links enable row level security;
create policy sel on public.leave_links for select to authenticated
  using (app.is_self(person_id) or app.can_view_person(person_id));

-- ------------------------------------------------------------- activity log
-- Written only by the SECURITY DEFINER audit trigger; read by access admins.
alter table public.activity_log enable row level security;
create policy sel on public.activity_log for select to authenticated
  using (app.is_admin() or (company_id is not null
         and app.has_capability(company_id, 'access.manage')));

-- ----------------------------------------------------------- table privileges
-- RLS is the gate; base grants mirror Supabase's defaults so the model also
-- runs on vanilla Postgres in CI.
grant usage on schema public to authenticated, anon, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
