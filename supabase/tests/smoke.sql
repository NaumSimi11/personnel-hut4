-- smoke.sql — behavioral verification of the schema + RLS on a scratch database.
-- Seeds a tiny scenario as superuser, then asserts what each simulated user
-- can and cannot see or do. Fails loudly (ON_ERROR_STOP) on any wrong answer.

-- ---------------------------------------------------------------- test data
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001','alex@a.test'),     -- director, Company A
  ('00000000-0000-0000-0000-000000000002','fiona@a.test'),    -- finance, Company A
  ('00000000-0000-0000-0000-000000000003','omar@a.test'),     -- employee, no grants
  ('00000000-0000-0000-0000-000000000004','ada@holding.test'),-- platform admin
  ('00000000-0000-0000-0000-000000000005','bea@b.test');      -- HR, Company B only

insert into public.companies (id, kind, name, short_code) values
  ('10000000-0000-0000-0000-00000000000a','company','Company A','A'),
  ('10000000-0000-0000-0000-00000000000b','company','Company B','B');

insert into public.people (id, user_id, full_name, work_email) values
  ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','Alex Director','alex@a.test'),
  ('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','Fiona Finance','fiona@a.test'),
  ('20000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003','Omar Employee','omar@a.test'),
  ('20000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000004','Ada Admin','ada@holding.test'),
  ('20000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000005','Bea HR','bea@b.test');

insert into public.employment_periods (id, person_id, company_id, job_title, status, start_date) values
  ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-00000000000a','Director','active','2024-01-01'),
  ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-00000000000a','Finance Specialist','active','2024-01-01'),
  ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-00000000000a','Engineer','active','2024-01-01'),
  ('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-00000000000a','Holding Admin','active','2024-01-01'),
  ('30000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-00000000000b','HR Manager','active','2024-01-01');

insert into public.platform_admins (person_id) values ('20000000-0000-0000-0000-000000000004');

-- Grants from presets: Alex ← Company Director @ A, Fiona ← Finance @ A.
insert into public.access_grants (id, person_id, company_id, source_preset_id) values
  ('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-00000000000a',
    (select id from public.permission_presets where name='Company Director')),
  ('40000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-00000000000a',
    (select id from public.permission_presets where name='Finance'));
insert into public.grant_capabilities (grant_id, capability_key)
select '40000000-0000-0000-0000-000000000001', capability_key
  from public.preset_capabilities
  where preset_id = (select id from public.permission_presets where name='Company Director');
insert into public.grant_capabilities (grant_id, capability_key)
select '40000000-0000-0000-0000-000000000002', capability_key
  from public.preset_capabilities
  where preset_id = (select id from public.permission_presets where name='Finance');

-- Bea: full Company HR preset, but ONLY in Company B.
insert into public.access_grants (id, person_id, company_id, source_preset_id) values
  ('40000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-00000000000b',
    (select id from public.permission_presets where name='Company HR'));
insert into public.grant_capabilities (grant_id, capability_key)
select '40000000-0000-0000-0000-000000000003', capability_key
  from public.preset_capabilities
  where preset_id = (select id from public.permission_presets where name='Company HR');

-- One approved salary for Omar; hiring requests in both companies.
insert into public.compensation_records
  (employment_period_id, amount, currency, pay_basis_key, effective_date, status) values
  ('30000000-0000-0000-0000-000000000003', 50000, 'EUR', 'annual', '2024-01-01', 'approved');

insert into public.hiring_requests (id, company_id, title, status) values
  ('60000000-0000-0000-0000-00000000000a','10000000-0000-0000-0000-00000000000a','Operations Coordinator','submitted'),
  ('60000000-0000-0000-0000-00000000000b','10000000-0000-0000-0000-00000000000b','Account Manager','submitted');

-- A Company A job with one candidate/application, a restricted departure
-- reason for Omar, and a configured workflow owner (audit coverage).
insert into public.jobs (id, company_id, title, status) values
  ('70000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-00000000000a','Operations Coordinator','open');
insert into public.candidates (id, full_name, email) values
  ('80000000-0000-0000-0000-000000000001','Cathy Candidate','cathy@example.test');
insert into public.applications (id, job_id, company_id, candidate_id) values
  ('90000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-00000000000a','80000000-0000-0000-0000-000000000001');
insert into public.employment_departure_details (employment_period_id, reason) values
  ('30000000-0000-0000-0000-000000000003','sample restricted departure detail');
insert into public.workflow_owners (company_id, role_key, person_id) values
  ('10000000-0000-0000-0000-00000000000a','hiring_approver','20000000-0000-0000-0000-000000000001');

-- Read-only project mirror: one Company A project, Omar is a member.
insert into public.external_projects (id, provider_key, external_id, company_id, name, status) values
  ('50000000-0000-0000-0000-000000000001','zoho_projects','ZP-1','10000000-0000-0000-0000-00000000000a','Website relaunch','Active');
insert into public.external_project_members (project_id, person_id) values
  ('50000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003');

-- --------------------------------------------------------------- assertions
-- Alex (Director @ A): sees Company A people and requests, but ZERO salaries.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  assert (select count(*) from public.people) = 4,
    'Director should see all 4 Company A people';
  assert (select count(*) from public.hiring_requests) = 1,
    'Director should see only Company A requests';
  assert (select count(*) from public.compensation_records) = 0,
    'Director must NOT see salaries without salary.view (the Sam rule)';
  assert (select count(*) from public.external_projects) = 1,
    'Director has projects.view, should see the synced project';
  assert (select count(*) from public.employment_departure_details) = 0,
    'Departure reasons are hidden from plain people.view holders';
end $$;

-- Positive path: Director approves the seeded request (not his own);
-- decided_by is server-set by the transition gate.
update public.hiring_requests set status = 'approved'
  where id = '60000000-0000-0000-0000-00000000000a';
do $$
begin
  assert (select status from public.hiring_requests
          where id = '60000000-0000-0000-0000-00000000000a') = 'approved',
    'Director with jobs.approve can approve a request';
  assert (select decided_by from public.hiring_requests
          where id = '60000000-0000-0000-0000-00000000000a')
         = '20000000-0000-0000-0000-000000000001',
    'decided_by must be server-set to the actual approver';
end $$;

-- Negative path: requesters never decide their own request.
insert into public.hiring_requests (id, company_id, title, status, requested_by) values
  ('60000000-0000-0000-0000-00000000000c','10000000-0000-0000-0000-00000000000a',
   'Office Manager','submitted','20000000-0000-0000-0000-000000000001');
do $$
begin
  begin
    update public.hiring_requests set status = 'approved'
      where id = '60000000-0000-0000-0000-00000000000c';
    raise exception 'FAIL: requester approved their own hiring request';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Director cannot write to the read-only projects mirror.
do $$
begin
  begin
    insert into public.external_projects (provider_key, external_id, company_id, name)
    values ('zoho_projects','ZP-X','10000000-0000-0000-0000-00000000000a','Rogue project');
    raise exception 'FAIL: director wrote to read-only projects mirror';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Fiona (Finance @ A): sees salaries; cannot propose changes; no projects.
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
do $$
begin
  assert (select count(*) from public.compensation_records) = 1,
    'Finance (salary.view) should see the approved salary';
  assert (select count(*) from public.external_projects) = 0,
    'Finance has no projects.view and is not a member: no projects visible';
  begin
    insert into public.compensation_records
      (employment_period_id, amount, currency, pay_basis_key, effective_date)
    values ('30000000-0000-0000-0000-000000000003', 60000, 'EUR', 'annual', '2025-01-01');
    raise exception 'FAIL: Finance proposed a salary without salary.propose';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Omar (no grants): self-service only.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  assert (select count(*) from public.people) = 1,
    'Ungranted employee sees only themself';
  assert (select count(*) from public.compensation_records) = 1,
    'Employee sees their own compensation';
  assert (select count(*) from public.hiring_requests) = 0,
    'Ungranted employee sees no hiring requests';
  assert (select count(*) from public.external_projects) = 1,
    'Project member sees their own project without projects.view';
  begin
    insert into public.hiring_requests (company_id, title)
    values ('10000000-0000-0000-0000-00000000000a','Rogue request');
    raise exception 'FAIL: ungranted employee created a hiring request';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- A temp-password session (must_change_password in app_metadata) is locked out
-- of everything but reference vocab, even for a fully-granted director.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set app.test_jwt = '{"app_metadata":{"must_change_password":true}}';
set role authenticated;
do $$
begin
  assert (select count(*) from public.people) = 0,
    'Pending-password session must not read people';
  assert (select count(*) from public.hiring_requests) = 0,
    'Pending-password session must not read hiring requests';
  assert (select count(*) from public.compensation_records) = 0,
    'Pending-password session must not read compensation';
  assert (select count(*) from public.external_projects) = 0,
    'Pending-password session must not read projects';
  begin
    update public.hiring_requests set title = 'x'
      where id = '60000000-0000-0000-0000-00000000000a';
    if found then
      raise exception 'FAIL: pending-password session wrote a hiring request';
    end if;
  end;
end $$;
reset role;
set app.test_jwt = '';

-- Ada (platform admin): sees across companies.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
begin
  assert (select count(*) from public.people) = 5, 'Admin sees everyone';
  assert (select count(*) from public.hiring_requests) = 3, 'Admin sees both companies';
  assert (select count(*) from public.compensation_records) = 1, 'Admin sees salaries';
  assert (select count(*) from public.employment_departure_details) = 1,
    'Admin sees departure details';
end $$;
reset role;

-- Bea (Company HR, but ONLY in Company B): the cross-company attack shapes.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare n int;
begin
  assert (select count(*) from public.people) = 1,
    'B-scoped HR sees only Company B people';
  -- right capability, wrong company: update must silently affect zero rows
  update public.people set full_name = 'HACKED'
    where id = '20000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  assert n = 0, 'B-scoped HR must not update a Company A person';
  -- …while the same capability works inside her own company
  update public.people set preferred_name = 'Bea'
    where id = '20000000-0000-0000-0000-000000000005';
  get diagnostics n = row_count;
  assert n = 1, 'B-scoped HR can update her own company''s person';
  -- Company A candidates are invisible despite candidates.review in B
  assert (select count(*) from public.candidates) = 0,
    'B-scoped HR must not see Company A candidates';
  assert (select count(*) from public.employment_departure_details) = 0,
    'B-scoped HR must not see Company A departure details';
  -- forged company_id on an application is server-corrected, then rejected
  begin
    insert into public.applications (job_id, company_id, candidate_id) values
      ('70000000-0000-0000-0000-000000000001',   -- Company A job
       '10000000-0000-0000-0000-00000000000b',   -- forged: claims Company B
       '80000000-0000-0000-0000-000000000001');
    raise exception 'FAIL: cross-company application insert accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- The attacked row is intact.
do $$
begin
  assert (select full_name from public.people
          where id = '20000000-0000-0000-0000-000000000001') = 'Alex Director',
    'Company A person untouched by cross-company update attempt';
end $$;

-- Structural guarantees (as superuser).
do $$
begin
  -- overlapping non-draft employment must be rejected
  begin
    insert into public.employment_periods (person_id, company_id, job_title, status, start_date)
    values ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-00000000000b','Moonlighter','active','2025-06-01');
    raise exception 'FAIL: overlapping employment accepted';
  exception when exclusion_violation then null;
  end;
  -- the last platform admin cannot be removed
  begin
    delete from public.platform_admins where person_id = '20000000-0000-0000-0000-000000000004';
    raise exception 'FAIL: last platform admin was deleted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;

-- confirm_hire: atomic, idempotent, capability-gated (migration 0009).
insert into public.candidates (id, full_name, email) values
  ('80000000-0000-0000-0000-000000000002','Hired Candidate','hired-candidate@example.test');
insert into public.applications (id, job_id, company_id, candidate_id, stage_key) values
  ('90000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-00000000000a','80000000-0000-0000-0000-000000000002','offer');

-- Alex (Director, NO employment.edit) is refused.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  begin
    perform public.confirm_hire('90000000-0000-0000-0000-000000000002',
      'Hired Candidate', 'Coordinator', current_date);
    raise exception 'FAIL: director confirmed a hire without employment.edit';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Ada (admin) confirms; a second confirm is a no-op returning the same result.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
declare first jsonb; again jsonb;
begin
  first := public.confirm_hire('90000000-0000-0000-0000-000000000002',
    'Hired Candidate', 'Coordinator', current_date);
  assert (first->>'already_hired')::boolean = false, 'first confirm creates';
  assert (select stage_key from public.applications
          where id = '90000000-0000-0000-0000-000000000002') = 'hired',
    'application moved to hired';
  assert (select count(*) from public.plan_tasks
          where plan_id = (first->>'plan_id')::uuid) = 5,
    'onboarding plan carries the 5 template tasks';
  again := public.confirm_hire('90000000-0000-0000-0000-000000000002',
    'Hired Candidate', 'Coordinator', current_date);
  assert (again->>'already_hired')::boolean = true, 'second confirm is a no-op';
  assert again->>'employment_period_id' = first->>'employment_period_id',
    'retry returns the same employment period';
  assert (select count(*) from public.employment_periods ep
          join public.people p on p.id = ep.person_id
          where p.work_email = 'hired-candidate@example.test') = 1,
    'exactly one employee results from one application';
end $$;
reset role;
set app.test_uid = '';

-- Departures: capability-gated, idempotent, and scheduling never deactivates
-- the person (migration 0010).
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona, Finance
set role authenticated;
do $$
begin
  begin
    perform public.schedule_departure('30000000-0000-0000-0000-000000000003',
      current_date + 30, current_date + 28, 'sample reason');
    raise exception 'FAIL: Finance scheduled a departure without departure.start';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada, admin
set role authenticated;
do $$
declare first jsonb; again jsonb; done jsonb;
begin
  first := public.schedule_departure('30000000-0000-0000-0000-000000000003',
    current_date + 30, current_date + 28, 'sample restricted reason');
  assert (first->>'already_scheduled')::boolean = false, 'first schedule creates a plan';
  assert (select status from public.employment_periods
          where id = '30000000-0000-0000-0000-000000000003') = 'active',
    'scheduling a departure must NOT deactivate the person';
  assert (select count(*) from public.plan_tasks
          where plan_id = (first->>'plan_id')::uuid) = 5,
    'offboarding plan carries the 5 template tasks';
  assert (select count(*) from public.plan_tasks
          where plan_id = (first->>'plan_id')::uuid
            and due_date = current_date + 28) = 2,
    'last-day tasks are dated from the last working day';

  again := public.schedule_departure('30000000-0000-0000-0000-000000000003',
    current_date + 31, current_date + 29, null);
  assert (again->>'already_scheduled')::boolean = true, 'second schedule is a no-op';
  assert again->>'plan_id' = first->>'plan_id', 'retry returns the same plan';
  assert (select count(*) from public.plans
          where employment_period_id = '30000000-0000-0000-0000-000000000003') = 1,
    'exactly one offboarding plan per employment period';

  -- Former while work is still outstanding is legitimate, and reported.
  done := public.complete_departure('30000000-0000-0000-0000-000000000003');
  assert (done->>'open_tasks')::int = 5, 'outstanding tasks are reported, not blocking';
  assert (select status from public.employment_periods
          where id = '30000000-0000-0000-0000-000000000003') = 'former',
    'completing a departure makes the person Former';
  assert (select status from public.plans
          where id = (first->>'plan_id')::uuid) = 'completed',
    'the offboarding plan is closed';
end $$;
reset role;

-- The restricted reason stays out of reach of plain people.view holders.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex, Director
set role authenticated;
do $$
begin
  assert (select count(*) from public.employment_departure_details) = 0,
    'departure reasons are not visible to people.view holders';
end $$;
reset role;
set app.test_uid = '';

-- Audit trail captured the grant writes.
do $$
begin
  assert (select count(*) from public.activity_log where entity_type = 'access_grants') >= 2,
    'Audit log should record access grant changes';
  assert (select count(*) from public.activity_log where entity_type = 'workflow_owners') >= 1,
    'Audit log should record workflow owner changes';
end $$;


-- ------------------------------------------------- company profile (0011)
-- Admins write the richer profile; the database validates brand colour and
-- guards the logo bucket; everyone else is read-only on companies.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada, admin
set role authenticated;
do $$
declare n int;
begin
  update public.companies set
    legal_name = 'Company A Ltd',
    registration_number = 'REG-1',
    tax_id = 'VAT-1',
    address_line1 = '1 Main St', city = 'Skopje', postcode = '1000', country = 'North Macedonia',
    website = 'https://a.test', contact_email = 'hello@a.test', contact_phone = '+389 2 000',
    director_person_id = '20000000-0000-0000-0000-000000000001',
    hr_contact_person_id = '20000000-0000-0000-0000-000000000004',
    brand = '{"accent_color":"#3e744e","tagline":"We build things","logo_path":"10000000-0000-0000-0000-00000000000a/logo.png"}'
    where id = '10000000-0000-0000-0000-00000000000a';
  get diagnostics n = row_count;
  assert n = 1, 'Admin can write the company profile';
  begin
    update public.companies set brand = '{"accent_color":"green"}'
      where id = '10000000-0000-0000-0000-00000000000a';
    raise exception 'FAIL: non-hex accent colour accepted';
  exception when check_violation then null;
  end;
  insert into storage.objects (bucket_id, name) values
    ('company-logos', '10000000-0000-0000-0000-00000000000a/logo.png');
  assert (select public from storage.buckets where id = 'company-logos'),
    'company-logos bucket is public';
end $$;
reset role;

set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex, Director
set role authenticated;
do $$
declare n int;
begin
  assert (select director_person_id from public.companies
          where id = '10000000-0000-0000-0000-00000000000a')
         = '20000000-0000-0000-0000-000000000001',
    'Everyone signed in can read the company profile';
  update public.companies set legal_name = 'HACKED'
    where id = '10000000-0000-0000-0000-00000000000a';
  get diagnostics n = row_count;
  assert n = 0, 'Non-admin must not write the company profile';
  begin
    insert into storage.objects (bucket_id, name) values ('company-logos', 'x/logo.png');
    raise exception 'FAIL: non-admin uploaded a company logo';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from storage.objects where bucket_id = 'company-logos') = 1,
    'Anyone can list company logos';
end $$;
reset role;
set app.test_uid = '';


-- ------------------------------------------- job workspace: promotions (0012)
-- Marketing collaboration is a state machine with separated duties: a drafter
-- writes, a different approver reviews, a publisher records the URL. Direct
-- status edits are closed; only advance_promotion moves a promotion.
-- Omar: Marketing (view + draft) plus approve, to prove self-review is refused.
insert into public.access_grants (id, person_id, company_id) values
  ('40000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-00000000000a');
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000004','marketing.view'),
  ('40000000-0000-0000-0000-000000000004','marketing.draft'),
  ('40000000-0000-0000-0000-000000000004','marketing.approve');
-- Fiona (Finance, Company A) additionally approves and publishes.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000002','marketing.view'),
  ('40000000-0000-0000-0000-000000000002','marketing.approve'),
  ('40000000-0000-0000-0000-000000000002','marketing.publish');

-- Ada (admin, holds jobs.edit everywhere) requests the promotion.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
insert into public.promotions (id, job_id, company_id, channel_key, brief, requested_by) values
  ('a0000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-00000000000a','linkedin',
   '{"title":"Operations Coordinator","company":"Company A"}',
   '20000000-0000-0000-0000-000000000004');
reset role;

-- Omar drafts and submits; cannot approve his own draft; cannot edit status directly.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare n int;
begin
  begin
    perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'draft', '', null);
    raise exception 'FAIL: empty copy accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'draft',
    'Join Company A as our Operations Coordinator.', null);
  assert (select status from public.promotions where id = 'a0000000-0000-0000-0000-000000000001') = 'draft',
    'drafter saves a draft';
  perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'in_review', null, null);
  assert (select status from public.promotions where id = 'a0000000-0000-0000-0000-000000000001') = 'in_review',
    'drafter submits for review';
  begin
    perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'approved', null, null);
    raise exception 'FAIL: drafter approved their own content';
  exception when insufficient_privilege then null;
  end;
  update public.promotions set status = 'published'
    where id = 'a0000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  assert n = 0, 'promotion status cannot be edited directly';
end $$;
reset role;

-- Fiona approves (not the drafter), then publishes with a URL.
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
do $$
begin
  begin
    perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'published', null, 'https://x.test/post');
    raise exception 'FAIL: published straight from review';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'approved', null, null);
  assert (select reviewed_by from public.promotions where id = 'a0000000-0000-0000-0000-000000000001')
         = '20000000-0000-0000-0000-000000000002', 'approver is recorded';
  begin
    perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'published', null, 'not a url');
    raise exception 'FAIL: published without a valid URL';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  perform public.advance_promotion('a0000000-0000-0000-0000-000000000001', 'published', null, 'https://x.test/post');
  assert (select status from public.promotions where id = 'a0000000-0000-0000-0000-000000000001') = 'published',
    'publisher records the post';
end $$;
reset role;

-- Activity: Alex (Director, jobs.view in A) reads the recruitment trail for
-- Company A; Bea (Company B only) sees none of it.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  assert (select count(*) from public.activity_log
          where entity_type = 'promotions' and entity_id = 'a0000000-0000-0000-0000-000000000001') >= 4,
    'jobs.view holders can read the promotion trail';
  assert (select count(*) from public.activity_log where entity_type = 'access_grants') = 0,
    'jobs.view does not open the access audit trail';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  assert (select count(*) from public.activity_log where entity_type = 'promotions') = 0,
    'Company B HR sees no Company A recruitment activity';
end $$;
reset role;
set app.test_uid = '';


-- Separation of duties cannot be sidestepped by rewriting the copy on submit,
-- and a cancelled promotion can be requested again (fresh brief, clean slate).
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada, admin
set role authenticated;
insert into public.promotions (id, job_id, company_id, channel_key, brief, requested_by) values
  ('a0000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-00000000000a','indeed', '{"title":"v1"}',
   '20000000-0000-0000-0000-000000000004');
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar drafts
set role authenticated;
select public.advance_promotion('a0000000-0000-0000-0000-000000000002', 'draft', 'Omar''s words', null, null);
reset role;
-- Omar (draft + approve) submits with rewritten copy, then tries to approve.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  perform public.advance_promotion('a0000000-0000-0000-0000-000000000002', 'in_review', 'Rewritten on submit', null, null);
  assert (select drafted_by from public.promotions where id = 'a0000000-0000-0000-0000-000000000002')
         = '20000000-0000-0000-0000-000000000003', 'rewriting on submit records the new drafter';
  begin
    perform public.advance_promotion('a0000000-0000-0000-0000-000000000002', 'approved', null, null, null);
    raise exception 'FAIL: drafter approved rewritten content';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
-- Ada cancels, then requests again with a fresh brief; the slate is clean.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
begin
  perform public.advance_promotion('a0000000-0000-0000-0000-000000000002', 'cancelled', null, null, null);
  perform public.advance_promotion('a0000000-0000-0000-0000-000000000002', 'requested', null, null, '{"title":"v2"}');
  assert (select status from public.promotions where id = 'a0000000-0000-0000-0000-000000000002') = 'requested',
    'a cancelled promotion can be requested again';
  assert (select brief->>'title' from public.promotions where id = 'a0000000-0000-0000-0000-000000000002') = 'v2',
    're-request refreshes the brief';
  assert (select copy is null and drafted_by is null and reviewed_by is null
          from public.promotions where id = 'a0000000-0000-0000-0000-000000000002'),
    're-request clears the previous draft and review';
end $$;
reset role;
set app.test_uid = '';


-- ------------------------------------------- candidate files & answers (0013)
-- Files hang off the application and inherit its company; the bucket is
-- private and both the row and the object follow candidates.view / review.
-- Alex (Director, Company A) also gets candidates.review, then attaches a CV.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'candidates.review');
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
declare v_id uuid;
begin
  insert into public.application_files
      (application_id, kind, storage_path, original_name, mime_type, size_bytes, uploaded_by)
    values ('90000000-0000-0000-0000-000000000001', 'cv',
            '90000000-0000-0000-0000-000000000001/f1.pdf', 'cathy-cv.pdf', 'application/pdf', 1234,
            '20000000-0000-0000-0000-000000000001')
    returning id into v_id;
  assert (select company_id from public.application_files where id = v_id)
         = '10000000-0000-0000-0000-00000000000a', 'file company is derived from the application';
  begin
    insert into public.application_files
        (application_id, company_id, kind, storage_path, original_name, mime_type, size_bytes)
      values ('90000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000b', 'cv',
              '90000000-0000-0000-0000-000000000001/forged.pdf', 'x.pdf', 'application/pdf', 1);
    -- the trigger overwrites the forged company, so this simply succeeds as A
  end;
  assert (select count(*) from public.application_files
          where company_id = '10000000-0000-0000-0000-00000000000b') = 0,
    'a forged company_id is corrected to the application''s company';
  insert into storage.objects (bucket_id, name) values
    ('candidate-files', '90000000-0000-0000-0000-000000000001/f1.pdf');
  assert (select public from storage.buckets where id = 'candidate-files') = false,
    'candidate-files bucket is private';
  update public.applications set screening_answers = '[{"question_id":"q1","answer":"Because"}]'
    where id = '90000000-0000-0000-0000-000000000001';
  assert (select screening_answers->0->>'answer' from public.applications
          where id = '90000000-0000-0000-0000-000000000001') = 'Because',
    'reviewer records screening answers';
end $$;
reset role;

-- Bea (Company B only) sees neither the file row nor the object.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  assert (select count(*) from public.application_files) = 0,
    'Company B HR sees no Company A candidate files';
  assert (select count(*) from storage.objects where bucket_id = 'candidate-files') = 0,
    'Company B HR sees no Company A candidate objects';
  begin
    insert into storage.objects (bucket_id, name) values
      ('candidate-files', '90000000-0000-0000-0000-000000000001/sneaky.pdf');
    raise exception 'FAIL: cross-company candidate upload accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Omar (employee, no recruitment capabilities) sees nothing either.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  assert (select count(*) from public.application_files) = 0,
    'plain employees see no candidate files';
end $$;
reset role;
set app.test_uid = '';


-- A stray object whose name is not application-keyed must not break reads
-- for everyone: the policy helper treats it as belonging to no company.
insert into storage.objects (bucket_id, name) values ('candidate-files', 'not-an-application/x.pdf');
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
begin
  assert (select count(*) from storage.objects where bucket_id = 'candidate-files') = 1,
    'reviewers still see their company''s objects when a junk-named object exists';
end $$;
reset role;
set app.test_uid = '';


-- ------------------------------------ interviews, scorecards, offers (0014)
-- Alex (candidates.review in A) schedules an interview with himself and Fiona
-- on the panel; Fiona (Finance, A: no candidates.* ) is given candidates.review
-- so she can score too. Scorecards are blind for panel members.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000002', 'candidates.view'),
  ('40000000-0000-0000-0000-000000000002', 'candidates.review'),
  ('40000000-0000-0000-0000-000000000002', 'offer.approve');

set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
insert into public.interviews (id, application_id, company_id, kind, scheduled_at, duration_minutes, created_by) values
  ('b0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-00000000000b',  -- forged: corrected to Company A by trigger
   'technical', now() + interval '2 days', 60, '20000000-0000-0000-0000-000000000001');
insert into public.interview_panel (interview_id, person_id) values
  ('b0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('b0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002');
do $$
begin
  assert (select company_id from public.interviews where id = 'b0000000-0000-0000-0000-000000000001')
         = '10000000-0000-0000-0000-00000000000a', 'interview company is derived from the application';
end $$;
reset role;

-- Fiona scores first.
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
insert into public.scorecards (id, interview_id, application_id, company_id, author_id, ratings, recommendation, summary) values
  ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
   '90000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-000000000002',
   '[{"criterion_id":"skills","label":"Role skills","rating":3,"evidence":"Solid"}]', 'yes', 'Good fit');
do $$
begin
  begin
    insert into public.scorecards (interview_id, application_id, company_id, author_id, ratings, recommendation) values
      ('b0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
       '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000001',  -- as Alex!
       '[]', 'yes');
    raise exception 'FAIL: scorecard accepted with a forged author';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Alex is on the panel and has not scored: Fiona's card is hidden from him.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  assert (select count(*) from public.scorecards where interview_id = 'b0000000-0000-0000-0000-000000000001') = 0,
    'panel member cannot read colleagues'' scorecards before submitting';
  insert into public.scorecards (interview_id, application_id, company_id, author_id, ratings, recommendation) values
    ('b0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
     '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000001',
     '[{"criterion_id":"skills","label":"Role skills","rating":2,"evidence":"Gaps"}]', 'no');
  assert (select count(*) from public.scorecards where interview_id = 'b0000000-0000-0000-0000-000000000001') = 2,
    'after submitting, the panel member sees every scorecard';
end $$;
reset role;

-- Ada (admin) is not on the panel: she sees both without scoring. Bea sees none.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
begin
  assert (select count(*) from public.scorecards) = 2, 'a reviewer off the panel sees all scorecards';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  assert (select count(*) from public.interviews) = 0, 'Company B HR sees no Company A interviews';
  assert (select count(*) from public.scorecards) = 0, 'Company B HR sees no Company A scorecards';
end $$;
reset role;

-- Offer: Alex drafts; cannot approve his own; Fiona approves; extended; accepted.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
insert into public.offers (id, application_id, company_id, terms, created_by) values
  ('d0000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-00000000000a', '{"salary":52000,"currency":"EUR","pay_basis":"annual","start_date":"2026-11-02"}',
   '20000000-0000-0000-0000-000000000001');
do $$
declare n int;
begin
  perform public.advance_offer('d0000000-0000-0000-0000-000000000001', 'in_approval', null);
  begin
    perform public.advance_offer('d0000000-0000-0000-0000-000000000001', 'approved', null);
    raise exception 'FAIL: author approved their own offer';
  exception when insufficient_privilege then null;
  end;
  update public.offers set status = 'approved' where id = 'd0000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  assert n = 0, 'offer status cannot be edited directly';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona: offer.approve
set role authenticated;
do $$
begin
  perform public.advance_offer('d0000000-0000-0000-0000-000000000001', 'approved', null);
  assert (select approved_by from public.offers where id = 'd0000000-0000-0000-0000-000000000001')
         = '20000000-0000-0000-0000-000000000002', 'approver is recorded';
end $$;
reset role;
-- Extending needs only candidates.review (Alex has no offer.approve).
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  perform public.advance_offer('d0000000-0000-0000-0000-000000000001', 'extended', null);
  assert (select status from public.offers where id = 'd0000000-0000-0000-0000-000000000001') = 'extended',
    'a reviewer without offer.approve can extend an approved offer';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
do $$
begin
  begin
    perform public.advance_offer('d0000000-0000-0000-0000-000000000001', 'declined', null);
    raise exception 'FAIL: declined without a reason';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  perform public.advance_offer('d0000000-0000-0000-0000-000000000001', 'accepted', null);
  assert (select status = 'accepted' and accepted_at is not null from public.offers
          where id = 'd0000000-0000-0000-0000-000000000001'), 'acceptance is timestamped';
end $$;
reset role;
set app.test_uid = '';


-- Authorship is server-set and immutable, so self-approval cannot be dodged
-- by inserting with a foreign or null created_by; scorecards cannot be moved
-- to another company by their author. (A second application: one open offer
-- per application is enforced by index.)
insert into public.candidates (id, full_name) values ('80000000-0000-0000-0000-000000000003', 'Carl Candidate');
insert into public.applications (id, job_id, company_id, candidate_id) values
  ('90000000-0000-0000-0000-000000000003', '70000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000003');
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona (review + approve)
set role authenticated;
insert into public.offers (id, application_id, company_id, terms, created_by) values
  ('d0000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-00000000000a', '{"salary":1}', null);
do $$
declare n int;
begin
  assert (select created_by from public.offers where id = 'd0000000-0000-0000-0000-000000000002')
         = '20000000-0000-0000-0000-000000000002', 'created_by is set from the session, not the client';
  update public.offers set created_by = '20000000-0000-0000-0000-000000000001'
    where id = 'd0000000-0000-0000-0000-000000000002';
  assert (select created_by from public.offers where id = 'd0000000-0000-0000-0000-000000000002')
         = '20000000-0000-0000-0000-000000000002', 'created_by cannot be changed';
  perform public.advance_offer('d0000000-0000-0000-0000-000000000002', 'in_approval', null);
  begin
    perform public.advance_offer('d0000000-0000-0000-0000-000000000002', 'approved', null);
    raise exception 'FAIL: author approved their own offer after tampering';
  exception when insufficient_privilege then null;
  end;
  update public.scorecards set company_id = '10000000-0000-0000-0000-00000000000b'
    where id = 'c0000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  assert (select company_id from public.scorecards where id = 'c0000000-0000-0000-0000-000000000001')
         = '10000000-0000-0000-0000-00000000000a', 'a scorecard stays in its interview''s company';
end $$;
reset role;
set app.test_uid = '';

select 'SMOKE TESTS PASSED' as result;
