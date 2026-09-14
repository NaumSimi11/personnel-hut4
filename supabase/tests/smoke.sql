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

-- ...unless they are a platform admin (0030): Ada raises and decides her own.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
insert into public.hiring_requests (id, company_id, title, status, requested_by) values
  ('60000000-0000-0000-0000-00000000000d','10000000-0000-0000-0000-00000000000a',
   'Group Accountant','submitted','20000000-0000-0000-0000-000000000004');
update public.hiring_requests set status = 'approved' where id = '60000000-0000-0000-0000-00000000000d';
do $$
begin
  assert (select status || '/' || decided_by::text from public.hiring_requests where id = '60000000-0000-0000-0000-00000000000d')
    = 'approved/20000000-0000-0000-0000-000000000004', 'admin decided their own request, decided_by server-set';
end $$;
set app.test_uid = '00000000-0000-0000-0000-000000000001';

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
  assert (select count(*) from public.hiring_requests) = 4, 'Admin sees both companies';
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


-- ------------------------------------------------ recruitment report (0015)
-- Company A has job 7000…01 (open) with: Cathy (new, careers), Carl (new,
-- added by hand), and the hired application 9000…02 (hired today, careers).
update public.applications set source_channel_key = 'careers'
  where id in ('90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002');
update public.applications set received_at = now() - interval '10 days'
  where id = '90000000-0000-0000-0000-000000000002';

set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex: jobs.view in A
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.recruitment_report('10000000-0000-0000-0000-00000000000a', current_date - 30, current_date);
  assert (r->'kpis'->>'open_roles')::int = 1, 'one open role';
  assert (r->'kpis'->>'received')::int = 3, 'three applications received in range';
  assert (r->'kpis'->>'hires')::int = 1, 'one hire in range';
  assert (r->'kpis'->>'median_days_to_hire')::numeric between 9 and 11, 'ten days to hire';
  assert (r->'kpis'->>'active_candidates')::int = 2, 'two candidates still in play';
  assert (select count(*) from jsonb_array_elements(r->'funnel')) = 1, 'funnel has the one job';
  assert (r->'funnel'->0->>'hired')::int = 1 and (r->'funnel'->0->'stages'->>'new')::int = 2,
    'funnel counts per stage';
  assert (select count(*) from jsonb_array_elements(r->'sources') s
          where s->>'source' = 'Company careers page' and (s->>'received')::int = 2 and (s->>'hired')::int = 1) = 1,
    'careers source: 2 received, 1 hired';
  assert (select count(*) from jsonb_array_elements(r->'sources') s
          where s->>'source' = 'Added by hand' and (s->>'received')::int = 1) = 1,
    'hand-added source counted';
  assert (r->'attention'->>'unassigned')::int = 2, 'unassigned open applications flagged';
end $$;
reset role;

-- Bea (Company B only) is refused; Omar (no jobs.view) is refused.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  begin
    perform public.recruitment_report('10000000-0000-0000-0000-00000000000a', current_date - 30, current_date);
    raise exception 'FAIL: Company B HR read Company A recruitment report';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';


-- ------------------------------------------------- employment changes (0016)
-- Alex (Director, A) gets employment.edit. Omar reports to Fiona; a change
-- dated today applies at once, a future one waits, a cycle is refused, a
-- department from Company B is refused, and Company B HR cannot touch A.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'employment.edit');
insert into public.departments (id, company_id, name) values
  ('e0000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'Operations'),
  ('e0000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'Sales B'),
  ('e0000000-0000-0000-0000-000000000000', null, 'Shared Finance');

set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare r jsonb; v_change uuid;
begin
  -- Omar (period 3000…03, currently former after the departure test — use
  -- Fiona's period 3000…02 as the subject instead): title + department + manager Alex, today.
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date,
    '{"job_title":"Finance Lead","department_id":"e0000000-0000-0000-0000-00000000000a","manager_id":"20000000-0000-0000-0000-000000000001"}',
    'Promotion');
  assert (r->>'applied')::boolean = true, 'a change dated today applies immediately';
  assert (select job_title from public.employment_periods where id = '30000000-0000-0000-0000-000000000002') = 'Finance Lead',
    'title updated';
  assert (select manager_id from public.employment_periods where id = '30000000-0000-0000-0000-000000000002')
         = '20000000-0000-0000-0000-000000000001', 'manager updated';

  -- Future change: recorded, not applied.
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date + 30,
    '{"job_title":"Head of Finance"}', 'Planned');
  assert (r->>'applied')::boolean = false, 'a future change is scheduled';
  v_change := (r->>'change_id')::uuid;
  assert (select job_title from public.employment_periods where id = '30000000-0000-0000-0000-000000000002') = 'Finance Lead',
    'today''s record is untouched by a future change';
  perform public.apply_due_employment_changes();
  assert (select status from public.employment_changes where id = v_change) = 'scheduled',
    'apply_due leaves future changes alone';
  perform public.cancel_employment_change(v_change);
  assert (select status from public.employment_changes where id = v_change) = 'cancelled', 'cancelled';

  -- Cycle: Fiona now reports to Alex; making Alex report to Fiona is refused.
  begin
    perform public.schedule_employment_change('30000000-0000-0000-0000-000000000001', current_date,
      '{"manager_id":"20000000-0000-0000-0000-000000000002"}', null);
    raise exception 'FAIL: circular reporting accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  -- Self-management refused.
  begin
    perform public.schedule_employment_change('30000000-0000-0000-0000-000000000001', current_date,
      '{"manager_id":"20000000-0000-0000-0000-000000000001"}', null);
    raise exception 'FAIL: self-management accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  -- Department from another company refused; a shared one is fine.
  begin
    perform public.schedule_employment_change('30000000-0000-0000-0000-000000000001', current_date,
      '{"department_id":"e0000000-0000-0000-0000-00000000000b"}', null);
    raise exception 'FAIL: foreign department accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  perform public.schedule_employment_change('30000000-0000-0000-0000-000000000001', current_date,
    '{"department_id":"e0000000-0000-0000-0000-000000000000"}', null);
  assert (select department_id from public.employment_periods where id = '30000000-0000-0000-0000-000000000001')
         = 'e0000000-0000-0000-0000-000000000000', 'shared department accepted';
  -- Effective date before the period start is refused.
  begin
    perform public.schedule_employment_change('30000000-0000-0000-0000-000000000001', '2000-01-01',
      '{"job_title":"x"}', null);
    raise exception 'FAIL: change before start accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;
reset role;

-- A future change becomes due: simulate by back-dating it, then apply.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
declare r jsonb; v_change uuid;
begin
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date + 1,
    '{"job_title":"Head of Finance"}', 'Planned');
  v_change := (r->>'change_id')::uuid;
end $$;
reset role;
update public.employment_changes set effective_date = current_date
  where status = 'scheduled' and changes->>'job_title' = 'Head of Finance';
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar: no employment.edit anywhere
set role authenticated;
do $$
begin
  assert public.apply_due_employment_changes() = 0, 'apply_due does nothing for a caller who may not edit employment';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex: employment.edit in A
set role authenticated;
do $$
begin
  assert public.apply_due_employment_changes() = 1, 'apply_due applies the one due change where the caller may edit';
end $$;
reset role;
-- Read back as superuser: Omar cannot see Fiona's period under RLS.
do $$
begin
  assert (select job_title from public.employment_periods where id = '30000000-0000-0000-0000-000000000002') = 'Head of Finance',
    'a due change is applied';
  assert (select count(*) from public.employment_changes where status = 'applied' and changes->>'job_title' = 'Head of Finance') = 1,
    'the change is marked applied';
end $$;

-- Bea (Company B) cannot schedule for Company A.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  begin
    perform public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date,
      '{"job_title":"Hacked"}', null);
    raise exception 'FAIL: Company B HR changed a Company A employment';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from public.employment_changes) = 0, 'Company B HR sees no Company A changes';
end $$;
reset role;
set app.test_uid = '';


-- Apply-time safety: a cycle that only exists once a scheduled change lands
-- is caught then and marked failed (not applied, not raised); an empty
-- employment type is refused up front; a departure cancels pending changes.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex (employment.edit)
set role authenticated;
do $$
declare r jsonb; v_future uuid;
begin
  -- Fiona currently reports to Alex (applied earlier). Schedule Alex → Fiona
  -- in 30 days: no cycle *today* because Alex has no manager yet...
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000001', current_date + 30,
    '{"manager_id":"20000000-0000-0000-0000-000000000002"}', 'reorg');
  raise exception 'FAIL: schedule accepted a manager who already reports to this person';
exception when raise_exception then
  if sqlerrm like 'FAIL:%' then raise; end if;
end $$;
do $$
declare r jsonb; v_future uuid;
begin
  -- Clear Fiona's manager today, then schedule Alex → Fiona (+30) and
  -- Fiona → Alex (+40): neither is a cycle today; together they are one
  -- once the first applies.
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date,
    '{"manager_id":""}', 'clear now');
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date + 30,
    '{"job_title":"Finance Partner"}', 'later title');
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000001', current_date + 30,
    '{"manager_id":"20000000-0000-0000-0000-000000000002"}', 'Alex reports to Fiona');
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date + 40,
    '{"manager_id":"20000000-0000-0000-0000-000000000001"}', 'would loop');
  v_future := (r->>'change_id')::uuid;
  -- Empty employment type is refused at schedule time.
  begin
    perform public.schedule_employment_change('30000000-0000-0000-0000-000000000002', current_date,
      '{"employment_type_key":""}', null);
    raise exception 'FAIL: empty employment type accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;
reset role;
-- Make the looping change due and apply: it must fail safely.
update public.employment_changes set effective_date = current_date
  where status = 'scheduled' and reason in ('Alex reports to Fiona', 'would loop');
do $$
begin
  perform public.apply_due_employment_changes();
  assert (select status from public.employment_changes where reason = 'would loop') = 'failed',
    'a change that would loop at apply time is marked failed';
  assert (select failure_reason from public.employment_changes where reason = 'would loop') ilike '%circular%',
    'the failure says why';
  assert (select manager_id from public.employment_periods where id = '30000000-0000-0000-0000-000000000002') is null,
    'the looping change was not applied';
end $$;
-- A departure completing cancels what is still scheduled for that period.
do $$
begin
  assert (select count(*) from public.employment_changes
          where employment_period_id = '30000000-0000-0000-0000-000000000002' and status = 'scheduled') = 1,
    'one change still scheduled for Fiona';
  update public.employment_periods set status = 'former', end_date = current_date
    where id = '30000000-0000-0000-0000-000000000002';
  assert (select count(*) from public.employment_changes
          where employment_period_id = '30000000-0000-0000-0000-000000000002' and status = 'scheduled') = 0,
    'becoming former cancels pending changes';
end $$;


-- ------------------------------------------------------- compensation (0017)
-- Alex (A) gets salary.propose; Fiona (Finance, A) gets salary.approve.
-- Omar has an approved 50000 EUR annual since 2024 (seeded above; his
-- period is now former, so use Alex's period 3000…01 as the subject).
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'salary.view'),
  ('40000000-0000-0000-0000-000000000001', 'salary.propose'),
  ('40000000-0000-0000-0000-000000000002', 'salary.approve');
insert into public.compensation_records
  (employment_period_id, amount, currency, pay_basis_key, effective_date, status) values
  ('30000000-0000-0000-0000-000000000001', 60000, 'EUR', 'annual', '2024-01-01', 'approved');

set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex proposes
set role authenticated;
do $$
declare r jsonb; n int;
begin
  r := public.propose_compensation('30000000-0000-0000-0000-000000000001', 66000, 'eur', 'annual', current_date, 'Market adjustment');
  assert (select status from public.compensation_records where id = (r->>'record_id')::uuid) = 'proposed', 'proposal recorded';
  assert (select currency from public.compensation_records where id = (r->>'record_id')::uuid) = 'EUR', 'currency upper-cased';
  begin
    perform public.propose_compensation('30000000-0000-0000-0000-000000000001', 70000, 'EUR', 'annual', current_date, null);
    raise exception 'FAIL: second open proposal accepted';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    perform public.decide_compensation((r->>'record_id')::uuid, 'approved', null);
    raise exception 'FAIL: proposer approved their own proposal';
  exception when insufficient_privilege then null;
  end;
  update public.compensation_records set status = 'approved' where id = (r->>'record_id')::uuid;
  get diagnostics n = row_count;
  assert n = 0, 'compensation status cannot be edited directly';
end $$;
reset role;

set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona approves
set role authenticated;
do $$
declare v_id uuid;
begin
  select id into v_id from public.compensation_records
    where employment_period_id = '30000000-0000-0000-0000-000000000001' and status = 'proposed';
  perform public.decide_compensation(v_id, 'approved', 'Agreed');
  assert (select status from public.compensation_records where id = v_id) = 'approved', 'approved';
  assert (select approved_by from public.compensation_records where id = v_id) = '20000000-0000-0000-0000-000000000002', 'approver recorded';
  assert (select status from public.compensation_records
          where employment_period_id = '30000000-0000-0000-0000-000000000001' and amount = 60000) = 'approved',
    'the previous record stays approved (closed by its end date, not a status flip)';
  assert (select end_date from public.compensation_records
          where employment_period_id = '30000000-0000-0000-0000-000000000001' and amount = 60000) = current_date - 1,
    'the previous record ends the day before';
  assert (select count(*) from public.compensation_records
          where employment_period_id = '30000000-0000-0000-0000-000000000001') = 2, 'history is kept';
  -- Fiona (payroll.summary) sees the company total: Alex 66000 annual; Omar's
  -- period is former so it is excluded.
  assert ((public.compensation_summary('10000000-0000-0000-0000-00000000000a')->'totals'->0->>'annualised')::numeric) = 66000,
    'payroll summary annualises current approved amounts';
end $$;
reset role;

-- Omar (no salary.*) sees only his own record; Bea (B) nothing; Omar cannot propose.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  assert (select count(*) from public.compensation_records) = 1, 'a person sees only their own compensation';
  begin
    perform public.propose_compensation('30000000-0000-0000-0000-000000000003', 1, 'EUR', 'annual', current_date, null);
    raise exception 'FAIL: proposal without salary.propose accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.compensation_summary('10000000-0000-0000-0000-00000000000a');
    raise exception 'FAIL: payroll summary without payroll.summary';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- Departure edges: a proposal effective after a scheduled end date is refused;
-- a proposal left open when the employment ends can be rejected, never
-- approved. Alex's period gets a far-future end date, then Dana's (4) goes
-- former with an open proposal. Headcount counts people, not records.
update public.employment_periods set end_date = '2100-01-01' where id = '30000000-0000-0000-0000-000000000001';
insert into public.compensation_records
  (employment_period_id, amount, currency, pay_basis_key, effective_date, status, proposed_by) values
  ('30000000-0000-0000-0000-000000000004', 1000, 'EUR', 'monthly', current_date, 'proposed', '20000000-0000-0000-0000-000000000001');
update public.employment_periods set status = 'former', end_date = current_date - 1 where id = '30000000-0000-0000-0000-000000000004';
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex proposes
set role authenticated;
do $$
begin
  begin
    perform public.propose_compensation('30000000-0000-0000-0000-000000000001', 70000, 'EUR', 'annual', '2100-02-01', null);
    raise exception 'FAIL: proposal effective after the employment ends accepted';
  exception when raise_exception then
    if sqlerrm not like '%after the employment ends%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona decides
set role authenticated;
do $$
declare v_id uuid := (select id from public.compensation_records where employment_period_id = '30000000-0000-0000-0000-000000000004');
begin
  begin
    perform public.decide_compensation(v_id, 'approved', null);
    raise exception 'FAIL: proposal approved on a former period';
  exception when raise_exception then
    if sqlerrm not like '%has ended%' then raise; end if;
  end;
  perform public.decide_compensation(v_id, 'rejected', 'Left the company');
  assert (select status from public.compensation_records where id = v_id) = 'rejected', 'open proposal rejected after departure';
  assert (public.compensation_summary('10000000-0000-0000-0000-00000000000a')->'totals'->0->>'people')::int = 1
     and (public.compensation_summary('10000000-0000-0000-0000-00000000000a')->>'covered')::int = 1,
    'headcount counts people on active employment';
end $$;
reset role;

-- --------------------------------------------------------- hardening (0018)
-- 1. The audit trail keeps identity and actors but never blind or salary content.
do $$
begin
  assert exists (select 1 from public.activity_log where entity_type = 'scorecards'), 'scorecards are still audited';
  assert exists (select 1 from public.activity_log where entity_type = 'compensation_records' and after ? 'status'),
    'compensation status changes are still audited';
  assert not exists (select 1 from public.activity_log where entity_type = 'scorecards'
                     and (coalesce(after, '{}') ? 'ratings' or coalesce(before, '{}') ? 'ratings'
                          or coalesce(after, '{}') ? 'recommendation')), 'scorecard content is not in the audit log';
  assert not exists (select 1 from public.activity_log where entity_type = 'compensation_records'
                     and (coalesce(after, '{}') ? 'amount' or coalesce(before, '{}') ? 'amount')),
    'compensation amounts are not in the audit log';
  assert not exists (select 1 from public.activity_log where entity_type = 'offers'
                     and (coalesce(after, '{}') ? 'terms' or coalesce(before, '{}') ? 'terms')),
    'offer terms are not in the audit log';
end $$;

-- 2. Cycle check within the company. Pia and Quinn work in A; Quinn reports
--    to Pia. Quinn is transferring: her A period ends soon and a later,
--    unmanaged pre-start period in B follows. Making Quinn Pia's manager in
--    A is still a loop and must be refused even though Quinn's latest period
--    is elsewhere.
insert into public.people (id, full_name) values
  ('20000000-0000-0000-0000-000000000021', 'Pia Planner'),
  ('20000000-0000-0000-0000-000000000022', 'Quinn Quant');
insert into public.employment_periods (id, person_id, company_id, job_title, status, start_date, end_date, manager_id) values
  ('30000000-0000-0000-0000-000000000021','20000000-0000-0000-0000-000000000021',
   '10000000-0000-0000-0000-00000000000a','Planner','active','2024-06-01', null, null),
  ('30000000-0000-0000-0000-000000000022','20000000-0000-0000-0000-000000000022',
   '10000000-0000-0000-0000-00000000000a','Analyst','active','2024-06-01', current_date + 10, '20000000-0000-0000-0000-000000000021'),
  ('30000000-0000-0000-0000-000000000023','20000000-0000-0000-0000-000000000022',
   '10000000-0000-0000-0000-00000000000b','Advisor','pre_start', current_date + 11, null, null);
-- 3. Apply-time re-validation fixture: a future change to Operations for Pia.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex (employment.edit in A)
set role authenticated;
do $$
declare r jsonb;
begin
  begin
    perform public.schedule_employment_change('30000000-0000-0000-0000-000000000021', current_date,
      '{"manager_id":"20000000-0000-0000-0000-000000000022"}', null);
    raise exception 'FAIL: cross-company period hid a reporting loop';
  exception when raise_exception then
    if sqlerrm not like '%circular%' then raise; end if;
  end;
  r := public.schedule_employment_change('30000000-0000-0000-0000-000000000021', current_date + 5,
    '{"department_id":"e0000000-0000-0000-0000-00000000000a"}', 'Move later');
  assert (r->>'applied')::boolean = false, 'future department change is scheduled';
end $$;
reset role;
set app.test_uid = '';
update public.departments set archived_at = now() where id = 'e0000000-0000-0000-0000-00000000000a';
update public.employment_changes set effective_date = current_date
  where employment_period_id = '30000000-0000-0000-0000-000000000021' and status = 'scheduled';
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  perform public.apply_due_employment_changes();
  assert (select status from public.employment_changes
          where employment_period_id = '30000000-0000-0000-0000-000000000021') = 'failed',
    'a change to an archived department fails at apply time';
  assert (select failure_reason from public.employment_changes
          where employment_period_id = '30000000-0000-0000-0000-000000000021') = 'Department not found.',
    'the reason names the guard';
end $$;
reset role;
set app.test_uid = '';

-- 4. One open application per candidate per job, enforced by the database.
insert into public.candidates (id, full_name, email) values
  ('80000000-0000-0000-0000-000000000018', 'Dana Duplicate', 'dana@example.test');
insert into public.applications (job_id, company_id, candidate_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000018');
do $$
begin
  begin
    insert into public.applications (job_id, company_id, candidate_id) values
      ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-000000000018');
    raise exception 'FAIL: second open application for the same candidate and job accepted';
  exception when unique_violation then null;
  end;
end $$;

-- --------------------------------------------------------- documents (0019)
-- Alex (A) gets documents.view + documents.upload. Provenance is server-set,
-- scope and categories are checked, a new version archives the old one,
-- lineage is frozen, and storage objects follow the rows' visibility.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'documents.view'),
  ('40000000-0000-0000-0000-000000000001', 'documents.upload');
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare v1 uuid; v2 uuid;
begin
  insert into public.documents (company_id, person_id, category_key, title, storage_path, visibility, uploaded_by, version)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'employment_agreement',
            '  Contract 2024 ', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/d1.pdf',
            'person_and_hr', '20000000-0000-0000-0000-000000000002', 7)
    returning id into v1;
  assert (select uploaded_by from public.documents where id = v1) = '20000000-0000-0000-0000-000000000001',
    'the uploader is the signed-in person, whatever the client sent';
  assert (select version from public.documents where id = v1) = 1, 'first version is 1';
  assert (select title from public.documents where id = v1) = 'Contract 2024', 'title trimmed';
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path)
      values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'registration', 'Test doc',
              '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/bad1.pdf');
    raise exception 'FAIL: company category accepted on a person document';
  exception when raise_exception then
    if sqlerrm not like '%company documents%' then raise; end if;
  end;
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path)
      values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000005', 'identification', 'Test doc',
              '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000005/bad2.pdf');
    raise exception 'FAIL: document for a person with no employment in the company accepted';
  exception when raise_exception then
    if sqlerrm not like '%no employment%' then raise; end if;
  end;
  -- New version.
  insert into public.documents (company_id, person_id, category_key, title, storage_path, supersedes_id)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'employment_agreement',
            'Contract 2024', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/d2.pdf', v1)
    returning id into v2;
  assert (select version from public.documents where id = v2) = 2, 'new version is 2';
  assert (select archived_at from public.documents where id = v1) is not null, 'the old version is archived';
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path, supersedes_id)
      values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'employment_agreement',
              'Test doc', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/bad3.pdf', v1);
    raise exception 'FAIL: superseding an archived document accepted';
  exception when raise_exception then
    if sqlerrm not like '%archived%' then raise; end if;
  end;
  update public.documents set version = 9, title = 'Renamed', uploaded_by = '20000000-0000-0000-0000-000000000002' where id = v2;
  assert (select version from public.documents where id = v2) = 2, 'version is frozen';
  assert (select uploaded_by from public.documents where id = v2) = '20000000-0000-0000-0000-000000000001', 'uploader is frozen';
  assert (select title from public.documents where id = v2) = 'Renamed', 'title may change';
  -- HR-only document and a company document.
  insert into public.documents (company_id, person_id, category_key, title, storage_path, visibility)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'other', 'HR note',
            '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/d3.pdf', 'hr_only');
  insert into public.documents (company_id, person_id, category_key, title, storage_path, visibility)
    values ('10000000-0000-0000-0000-00000000000a', null, 'registration', 'Company registration',
            '10000000-0000-0000-0000-00000000000a/company/c1.pdf', 'company_public');
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path)
      values ('10000000-0000-0000-0000-00000000000a', null, 'identification', 'Test doc',
              '10000000-0000-0000-0000-00000000000a/company/bad4.pdf');
    raise exception 'FAIL: person category accepted on a company document';
  exception when raise_exception then
    if sqlerrm not like '%person''s documents%' then raise; end if;
  end;
  -- Storage: objects only under a company where Alex may upload.
  insert into storage.objects (bucket_id, name) values
    ('employee-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/d2.pdf'),
    ('employee-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/d3.pdf');
  begin
    insert into storage.objects (bucket_id, name) values ('employee-documents', '10000000-0000-0000-0000-00000000000b/company/z.pdf');
    raise exception 'FAIL: upload into another company''s folder accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into storage.objects (bucket_id, name) values ('employee-documents', 'not-a-uuid/z.pdf');
    raise exception 'FAIL: upload outside a company folder accepted';
  exception when insufficient_privilege then null;
  end;
  -- An upload whose row was refused can be cleaned up by the uploader.
  insert into storage.objects (bucket_id, name) values
    ('employee-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/orphan.pdf');
  delete from storage.objects where bucket_id = 'employee-documents' and name like '%/orphan.pdf';
  assert not exists (select 1 from storage.objects where name like '%/orphan.pdf'), 'the uploader can remove an orphaned object';
end $$;
reset role;

-- Omar (self; former in A but still holding grants there): sees his
-- person_and_hr versions and the public company document, never the HR-only
-- note, and only the object a visible row points to.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  assert (select count(*) from public.documents where person_id = '20000000-0000-0000-0000-000000000003') = 2,
    'the person sees both versions of their own document';
  assert not exists (select 1 from public.documents where title = 'HR note'), 'hr_only stays with HR';
  assert (select count(*) from storage.objects where bucket_id = 'employee-documents') = 1,
    'only the object behind a visible row is readable';
  assert exists (select 1 from public.documents where title = 'Company registration'),
    'a grant holder in the company sees its public documents';
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path)
      values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'other', 'mine',
              '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/self.pdf');
    raise exception 'FAIL: self-upload without documents.upload accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
-- Bea (Company B HR) sees nothing of Company A.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  assert (select count(*) from public.documents) = 0, 'other-company HR sees no documents';
  assert (select count(*) from storage.objects where bucket_id = 'employee-documents') = 0, 'nor their objects';
end $$;
reset role;
set app.test_uid = '';

-- ------------------------------------------------------ hardening 2 (0020)
-- 1. Direct inserts cannot skip the offer / promotion state machines.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada (admin holds jobs.edit)
set role authenticated;
do $$
declare v_id uuid;
begin
  insert into public.promotions (job_id, company_id, channel_key, status, copy, drafted_by)
    values ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'other_manual', 'in_review',
            'Copy written straight into review', null)
    returning id into v_id;
  assert (select status from public.promotions where id = v_id) = 'requested', 'a promotion always starts requested';
  assert (select copy from public.promotions where id = v_id) is null, 'and without copy';
  assert (select requested_by from public.promotions where id = v_id) = '20000000-0000-0000-0000-000000000004',
    'requested by the signed-in person';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex: candidates.review in A
set role authenticated;
do $$
declare v_id uuid;
begin
  insert into public.offers (application_id, company_id, terms, status, approved_by, accepted_at)
    values ((select id from public.applications where candidate_id = '80000000-0000-0000-0000-000000000018' limit 1),
            '10000000-0000-0000-0000-00000000000a', '{"salary": 1}', 'accepted',
            '20000000-0000-0000-0000-000000000002', now())
    returning id into v_id;
  assert (select status from public.offers where id = v_id) = 'draft', 'an offer always starts as a draft';
  assert (select approved_by from public.offers where id = v_id) is null, 'with no approver';
  assert (select accepted_at from public.offers where id = v_id) is null, 'and not accepted';
  delete from public.offers where id = v_id;
end $$;
reset role;
set app.test_uid = '';
delete from public.offers where terms = '{"salary": 1}'::jsonb;

-- 2. A promotion seeded into review with no drafter (service role only, now
--    that inserts are pinned) is reviewable by an approver; the compare is
--    null-safe so it never depends on SQL three-valued logic.
update public.promotions set status = 'in_review', copy = 'Seeded straight into review', drafted_by = null
  where channel_key = 'other_manual' and job_id = '70000000-0000-0000-0000-000000000001';
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar holds marketing.approve
set role authenticated;
do $$
begin
  perform public.advance_promotion(
    (select id from public.promotions where channel_key = 'other_manual' and job_id = '70000000-0000-0000-0000-000000000001'),
    'approved');
  assert (select status from public.promotions where channel_key = 'other_manual'
          and job_id = '70000000-0000-0000-0000-000000000001') = 'approved',
    'a reviewer who is not the drafter approves';
end $$;
reset role;
set app.test_uid = '';

-- 3. Approving a future-dated raise keeps the current record in force.
insert into public.compensation_records (employment_period_id, amount, currency, pay_basis_key, effective_date, status, proposed_by) values
  ('30000000-0000-0000-0000-000000000021', 1000, 'EUR', 'monthly', '2025-01-01', 'approved', null),
  ('30000000-0000-0000-0000-000000000021', 1200, 'EUR', 'monthly', current_date + 60, 'proposed', '20000000-0000-0000-0000-000000000001');
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000002', 'payroll.summary')
on conflict do nothing;
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona: salary.approve + payroll.summary
set role authenticated;
do $$
declare v_before numeric; v_after numeric;
begin
  v_before := (select sum((t->>'annualised')::numeric) from jsonb_array_elements(
    public.compensation_summary('10000000-0000-0000-0000-00000000000a')->'totals') t);
  perform public.decide_compensation(
    (select id from public.compensation_records where employment_period_id = '30000000-0000-0000-0000-000000000021' and status = 'proposed'),
    'approved');
  v_after := (select sum((t->>'annualised')::numeric) from jsonb_array_elements(
    public.compensation_summary('10000000-0000-0000-0000-00000000000a')->'totals') t);
  assert v_after = v_before, 'a future raise changes nothing in today''s payroll total';
  assert (select status from public.compensation_records where employment_period_id = '30000000-0000-0000-0000-000000000021' and amount = 1000)
         = 'approved', 'the current record stays approved';
  assert (select end_date from public.compensation_records where employment_period_id = '30000000-0000-0000-0000-000000000021' and amount = 1000)
         = current_date + 59, 'and ends the day before the raise';
end $$;
reset role;
set app.test_uid = '';

-- 4. Due changes apply only where the caller may edit employment.
insert into public.employment_changes (employment_period_id, company_id, effective_date, changes, status)
  values ('30000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000b', current_date - 1,
          '{"job_title":"HR Lead"}', 'scheduled');
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex: employment.edit in A only
set role authenticated;
do $$
begin
  perform public.apply_due_employment_changes();
end $$;
reset role;
set app.test_uid = '';
do $$
begin
  assert (select status from public.employment_changes where employment_period_id = '30000000-0000-0000-0000-000000000005') = 'scheduled',
    'a change in another company waits for someone who may apply it';
  perform public.apply_due_employment_changes();   -- service role / scheduler: everywhere
  assert (select status from public.employment_changes where employment_period_id = '30000000-0000-0000-0000-000000000005') = 'applied',
    'the scheduler applies it';
end $$;

-- 5. A direct manager edit cannot create a loop: Quinn reports to Pia (0018 test).
do $$
begin
  begin
    update public.employment_periods set manager_id = '20000000-0000-0000-0000-000000000022'
      where id = '30000000-0000-0000-0000-000000000021';
    raise exception 'FAIL: direct update created a reporting loop';
  exception when raise_exception then
    if sqlerrm not like '%circular%' then raise; end if;
  end;
  begin
    update public.employment_periods set manager_id = person_id where id = '30000000-0000-0000-0000-000000000021';
    raise exception 'FAIL: self-management accepted';
  exception when raise_exception then
    if sqlerrm not like '%own manager%' then raise; end if;
  end;
end $$;

-- 6. Candidate file audit rows carry no text or file names.
do $$
begin
  assert not exists (select 1 from public.activity_log where entity_type = 'application_files'
                     and (coalesce(after, '{}') ? 'extracted_text' or coalesce(after, '{}') ? 'original_name')),
    'application_files audit is redacted';
end $$;

-- 7. A company website is a web URL or nothing.
do $$
begin
  begin
    update public.companies set website = 'javascript:alert(1)' where id = '10000000-0000-0000-0000-00000000000a';
    raise exception 'FAIL: non-web website accepted';
  exception when check_violation then null;
  end;
end $$;

-- ------------------------------------------ document requests & policies (0021)
-- Alex (A) gets documents.request and policies.publish. Omar (self, still
-- granted in A) fulfils a request through the self-service window and
-- acknowledges policies; Ada publishes holding-wide.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'documents.request'),
  ('40000000-0000-0000-0000-000000000001', 'policies.publish');
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare v_req uuid;
begin
  insert into public.document_requests (company_id, person_id, category_key, due_date, status, note)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'identification',
            current_date + 7, 'accepted', '  Passport copy ')
    returning id into v_req;
  assert (select status from public.document_requests where id = v_req) = 'pending', 'a request always starts pending';
  assert (select reviewer_id from public.document_requests where id = v_req) = '20000000-0000-0000-0000-000000000001',
    'the requester is the reviewer';
  assert (select note from public.document_requests where id = v_req) = 'Passport copy', 'note trimmed';
  begin
    insert into public.document_requests (company_id, person_id, category_key)
      values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'registration');
    raise exception 'FAIL: company category accepted on a request';
  exception when raise_exception then
    if sqlerrm not like '%person document category%' then raise; end if;
  end;
  begin
    perform public.review_document_request(v_req, 'accepted', null);
    raise exception 'FAIL: accepted a request nothing was submitted for';
  exception when raise_exception then
    if sqlerrm not like '%Only a submitted%' then raise; end if;
  end;
end $$;
reset role;

-- Omar: no documents.upload, but an open request opens the self-service window.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare v_req uuid := (select id from public.document_requests where person_id = '20000000-0000-0000-0000-000000000003' and category_key = 'identification');
        v_doc uuid; n int;
begin
  assert v_req is not null, 'the person sees their own request';
  insert into storage.objects (bucket_id, name) values
    ('employee-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/self1.pdf');
  begin
    insert into storage.objects (bucket_id, name) values
      ('employee-documents', '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-000000000003/self-b.pdf');
    raise exception 'FAIL: self upload into a company with no open request accepted';
  exception when insufficient_privilege then null;
  end;
  insert into public.documents (company_id, person_id, category_key, title, storage_path, visibility)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'identification', 'My passport',
            '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/self1.pdf', 'hr_only')
    returning id into v_doc;
  assert (select visibility from public.documents where id = v_doc) = 'person_and_hr',
    'a self-service upload is always person_and_hr';
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path)
      values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'other', 'Unrequested',
              '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/self2.pdf');
    raise exception 'FAIL: self upload outside the requested category accepted';
  exception when insufficient_privilege then null;
  end;
  update public.document_requests set status = 'accepted' where id = v_req;
  get diagnostics n = row_count;
  assert (select status from public.document_requests where id = v_req) = 'pending', 'status cannot be edited directly';
  perform public.submit_requested_document(v_req, v_doc);
  assert (select status from public.document_requests where id = v_req) = 'submitted', 'submitted through the function';
  assert (select fulfilled_document_id from public.document_requests where id = v_req) = v_doc, 'linked to the document';
  begin
    perform public.review_document_request(v_req, 'accepted', null);
    raise exception 'FAIL: the person reviewed their own request';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Alex sends it back, Omar re-submits a new version, Alex accepts; the window closes.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
select public.review_document_request(
  (select id from public.document_requests where person_id = '20000000-0000-0000-0000-000000000003' and category_key = 'identification'),
  'needs_correction', 'Both pages please');
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare v_req uuid := (select id from public.document_requests where person_id = '20000000-0000-0000-0000-000000000003' and category_key = 'identification');
        v_old uuid := (select id from public.documents where title = 'My passport' and archived_at is null);
        v_doc uuid;
begin
  assert (select status from public.document_requests where id = v_req) = 'needs_correction', 'sent back';
  assert (select note from public.document_requests where id = v_req) like '%Both pages please', 'with the reason';
  insert into public.documents (company_id, person_id, category_key, title, storage_path, supersedes_id)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'identification', 'My passport',
            '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/self3.pdf', v_old)
    returning id into v_doc;
  assert (select version from public.documents where id = v_doc) = 2, 'the correction is a new version';
  perform public.submit_requested_document(v_req, v_doc);
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
select public.review_document_request(
  (select id from public.document_requests where person_id = '20000000-0000-0000-0000-000000000003' and category_key = 'identification'),
  'accepted', null);
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  assert (select status from public.document_requests where person_id = '20000000-0000-0000-0000-000000000003'
          and category_key = 'identification') = 'accepted', 'accepted';
  begin
    insert into storage.objects (bucket_id, name) values
      ('employee-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/late.pdf');
    raise exception 'FAIL: self upload after the request closed accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Policies: draft → publish needs a file → v1 → acknowledged → re-publish v2.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex publishes in A
set role authenticated;
do $$
declare v_pol uuid;
begin
  insert into public.policies (company_id, title, status, version) values
    ('10000000-0000-0000-0000-00000000000a', ' Code of conduct ', 'published', 9)
    returning id into v_pol;
  assert (select status from public.policies where id = v_pol) = 'draft', 'a policy starts as a draft';
  assert (select version from public.policies where id = v_pol) = 1, 'at version 1';
  assert (select title from public.policies where id = v_pol) = 'Code of conduct', 'title trimmed';
  begin
    perform public.publish_policy(v_pol);
    raise exception 'FAIL: published without a file';
  exception when raise_exception then
    if sqlerrm not like '%Attach the policy document%' then raise; end if;
  end;
  insert into storage.objects (bucket_id, name) values ('policies', '10000000-0000-0000-0000-00000000000a/' || v_pol || '.pdf');
  begin
    insert into storage.objects (bucket_id, name) values ('policies', 'holding/' || v_pol || '.pdf');
    raise exception 'FAIL: company publisher wrote a holding-wide object';
  exception when insufficient_privilege then null;
  end;
  update public.policies set storage_path = '10000000-0000-0000-0000-00000000000a/' || v_pol || '.pdf', status = 'published' where id = v_pol;
  assert (select status from public.policies where id = v_pol) = 'draft', 'status cannot be edited directly';
  perform public.publish_policy(v_pol);
  assert (select status from public.policies where id = v_pol) = 'published', 'published';
  assert (select published_by from public.policies where id = v_pol) = '20000000-0000-0000-0000-000000000001', 'by Alex';
  begin
    insert into public.policies (company_id, title) values (null, 'Holding-wide by Alex');
    raise exception 'FAIL: company publisher created a holding-wide policy';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar reads and acknowledges
set role authenticated;
do $$
declare v_pol uuid := (select id from public.policies where title = 'Code of conduct');
begin
  assert v_pol is not null, 'a person in the company sees the published policy';
  assert (select count(*) from storage.objects where bucket_id = 'policies') = 1, 'and can read its file';
  perform public.acknowledge_policy(v_pol);
  perform public.acknowledge_policy(v_pol);
  assert (select count(*) from public.policy_acknowledgements where policy_id = v_pol) = 1, 'acknowledged once per version';
  assert (select version from public.policy_acknowledgements where policy_id = v_pol) = 1, 'version 1';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
declare v_pol uuid := (select id from public.policies where title = 'Code of conduct');
begin
  insert into storage.objects (bucket_id, name) values ('policies', '10000000-0000-0000-0000-00000000000a/' || v_pol || '/v2.pdf');
  perform public.publish_policy(v_pol, '10000000-0000-0000-0000-00000000000a/' || v_pol || '/v2.pdf', 'conduct-v2.pdf', 'application/pdf');
  assert (select version from public.policies where id = v_pol) = 2, 'a re-publish with a new file is a new version';
  assert (select count(*) from public.policy_acknowledgements where policy_id = v_pol and version = 2) = 0,
    'earlier acknowledgements do not count for it';
  assert (select count(*) from public.policy_acknowledgements where policy_id = v_pol) = 1, 'HR sees who acknowledged';
end $$;
reset role;
-- Holding-wide: Ada publishes, Bea (Company B) sees and acknowledges.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada, admin
set role authenticated;
do $$
declare v_pol uuid;
begin
  insert into public.policies (company_id, title) values (null, 'Group travel policy') returning id into v_pol;
  insert into storage.objects (bucket_id, name) values ('policies', 'holding/' || v_pol || '.pdf');
  update public.policies set storage_path = 'holding/' || v_pol || '.pdf' where id = v_pol;
  perform public.publish_policy(v_pol);
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea
set role authenticated;
do $$
declare v_pol uuid := (select id from public.policies where title = 'Group travel policy');
begin
  assert v_pol is not null, 'everyone sees a holding-wide policy';
  assert not exists (select 1 from public.policies where title = 'Code of conduct'), 'but not another company''s';
  perform public.acknowledge_policy(v_pol);
  assert (select count(*) from public.policy_acknowledgements where policy_id = v_pol) = 1, 'acknowledged';
end $$;
reset role;
set app.test_uid = '';

-- 0021 review fixes: no direct acknowledgements, a published file is frozen,
-- a new version needs a new file, the self window allows cleanup, a
-- superseding upload keeps the category.
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
declare v_pol uuid := (select id from public.policies where title = 'Code of conduct');
begin
  begin
    insert into public.policy_acknowledgements (policy_id, person_id, version) values (v_pol, '20000000-0000-0000-0000-000000000003', 3);
    raise exception 'FAIL: direct acknowledgement accepted';
  exception when insufficient_privilege then null;
  end;
  assert app.has_open_document_request('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'identification') = false,
    'the window function never answers for someone else';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare v_pol uuid := (select id from public.policies where title = 'Code of conduct');
        v_old uuid := (select id from public.documents where title = 'My passport' and archived_at is null);
begin
  begin
    update public.policies set storage_path = 'x/y.pdf' where id = v_pol;
    raise exception 'FAIL: changed the file of a published policy';
  exception when raise_exception then
    if sqlerrm not like '%Publish a new version%' then raise; end if;
  end;
  begin
    perform public.publish_policy(v_pol);
    raise exception 'FAIL: re-published without a new file';
  exception when raise_exception then
    if sqlerrm not like '%Attach the new file%' then raise; end if;
  end;
  insert into storage.objects (bucket_id, name) values ('policies', '10000000-0000-0000-0000-00000000000a/' || v_pol || '/v3.pdf');
  perform public.publish_policy(v_pol, '10000000-0000-0000-0000-00000000000a/' || v_pol || '/v3.pdf', 'conduct-v3.pdf', 'application/pdf');
  assert (select version from public.policies where id = v_pol) = 3, 'new file, new version';
  assert (select storage_path from public.policies where id = v_pol) like '%/v3.pdf', 'file attached with the version';
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path, supersedes_id)
      values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'other', 'Wrong category',
              '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/wrong.pdf', v_old);
    raise exception 'FAIL: a new version changed category';
  exception when raise_exception then
    if sqlerrm not like '%same person, company and category%' then raise; end if;
  end;
  -- A fresh request re-opens Omar's window so the cleanup path can be shown.
  insert into public.document_requests (company_id, person_id, category_key)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'onboarding_form');
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
begin
  insert into storage.objects (bucket_id, name) values
    ('employee-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000003/orphan-self.pdf');
  delete from storage.objects where name like '%/orphan-self.pdf';
  assert not exists (select 1 from storage.objects where name like '%/orphan-self.pdf'), 'the person can take back an orphaned self upload';
end $$;
reset role;
set app.test_uid = '';

-- --------------------------------------------------------- equipment (0022)
-- Alex (A) gets the IT capabilities. Status follows the assignment functions,
-- one open assignment per asset, people must be employed in the company,
-- IT requests are pinned and advanced through advance_it_request.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'it.view'),
  ('40000000-0000-0000-0000-000000000001', 'it.assign'),
  ('40000000-0000-0000-0000-000000000001', 'it.complete');
insert into public.locations (id, company_id, name) values ('f0000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'B Office');
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare v_asset uuid; v_a uuid; r jsonb; v_req uuid; n int;
begin
  insert into public.assets (company_id, asset_tag, type_key, model, status)
    values ('10000000-0000-0000-0000-00000000000a', ' lt-001 ', 'laptop', 'ThinkPad T14', 'lost')
    returning id into v_asset;
  assert (select asset_tag from public.assets where id = v_asset) = 'LT-001', 'tag normalised';
  assert (select status from public.assets where id = v_asset) = 'available', 'a new asset is available';
  update public.assets set status = 'lost', model = 'ThinkPad T14 Gen 3' where id = v_asset;
  assert (select status from public.assets where id = v_asset) = 'available', 'status is not edited directly';
  assert (select model from public.assets where id = v_asset) = 'ThinkPad T14 Gen 3', 'facts are';
  begin
    update public.assets set location_id = 'f0000000-0000-0000-0000-00000000000b' where id = v_asset;
    raise exception 'FAIL: location from another company accepted';
  exception when raise_exception then
    if sqlerrm not like '%another company%' then raise; end if;
  end;

  begin
    perform public.reserve_asset(v_asset, '20000000-0000-0000-0000-000000000003', null);   -- Omar: former in A
    raise exception 'FAIL: reserved for someone without current employment';
  exception when raise_exception then
    if sqlerrm not like '%no current employment%' then raise; end if;
  end;
  r := public.reserve_asset(v_asset, '20000000-0000-0000-0000-000000000021', 'For the new project');
  v_a := (r->>'assignment_id')::uuid;
  assert (select status from public.assets where id = v_asset) = 'reserved', 'reserved';
  begin
    perform public.reserve_asset(v_asset, '20000000-0000-0000-0000-000000000022', null);
    raise exception 'FAIL: reserved an asset that is not available';
  exception when raise_exception then
    if sqlerrm not like '%only an available asset%' then raise; end if;
  end;
  begin
    perform public.return_asset(v_a, null, 'available');
    raise exception 'FAIL: returned an asset that was never issued';
  exception when raise_exception then
    if sqlerrm not like '%never issued%' then raise; end if;
  end;
  perform public.issue_asset(v_a);
  assert (select status from public.assets where id = v_asset) = 'assigned', 'issued';
  assert (select issued_by from public.asset_assignments where id = v_a) = '20000000-0000-0000-0000-000000000001', 'issued by Alex';
  update public.asset_assignments set returned_at = now() where id = v_a;
  get diagnostics n = row_count;
  assert n = 0, 'assignments are not edited directly';
  begin
    perform public.return_asset(v_a, 'scratched lid', 'sold');
    raise exception 'FAIL: unknown status after return accepted';
  exception when raise_exception then
    if sqlerrm not like '%available, damaged, lost or retired%' then raise; end if;
  end;
  perform public.return_asset(v_a, 'scratched lid', 'damaged');
  assert (select status from public.assets where id = v_asset) = 'damaged', 'status after return';
  assert (select condition from public.assets where id = v_asset) = 'scratched lid', 'condition recorded';
  assert (select returned_at from public.asset_assignments where id = v_a) is not null, 'assignment closed';
  begin
    perform public.cancel_reservation(v_a);
    raise exception 'FAIL: cancelled a closed assignment';
  exception when raise_exception then
    if sqlerrm not like '%Only an open reservation%' then raise; end if;
  end;

  -- IT request.
  insert into public.it_requests (company_id, person_id, kind, title, requested_systems, status, requested_by, assignee_id)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000021', 'manual', '  Laptop setup ',
            '["email","vpn"]', 'done', '20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002')
    returning id into v_req;
  assert (select status from public.it_requests where id = v_req) = 'open', 'a request starts open';
  assert (select requested_by from public.it_requests where id = v_req) = '20000000-0000-0000-0000-000000000001', 'requested by the signed-in person';
  assert (select assignee_id from public.it_requests where id = v_req) is null, 'unassigned';
  assert (select title from public.it_requests where id = v_req) = 'Laptop setup', 'title trimmed';
  update public.it_requests set status = 'done' where id = v_req;
  assert (select status from public.it_requests where id = v_req) = 'open', 'status is not edited directly';
  begin
    perform public.advance_it_request(v_req, 'blocked', null, '  ');
    raise exception 'FAIL: blocked without a reason';
  exception when raise_exception then
    if sqlerrm not like '%what blocks it%' then raise; end if;
  end;
  perform public.advance_it_request(v_req, 'in_progress');
  assert (select assignee_id from public.it_requests where id = v_req) = '20000000-0000-0000-0000-000000000001', 'picking it up assigns it';
  perform public.advance_it_request(v_req, 'blocked', null, 'Waiting for the licence');
  assert (select blocked_reason from public.it_requests where id = v_req) = 'Waiting for the licence', 'reason kept';
  perform public.advance_it_request(v_req, 'done');
  assert (select blocked_reason from public.it_requests where id = v_req) is null, 'reason cleared when done';
  begin
    perform public.advance_it_request(v_req, 'open');
    raise exception 'FAIL: reopened a done request';
  exception when raise_exception then
    if sqlerrm not like '%already done%' then raise; end if;
  end;
end $$;
reset role;
-- The holder sees what they hold (no IT capability needed); once it is
-- returned the register is HR/IT business again.
set app.test_uid = '';
select set_config('app.smoke_asset', id::text, false) from public.assets where asset_tag = 'LT-001';
update public.assets set status = 'available' where asset_tag = 'LT-001';   -- superuser: reset for the next scenario
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000021', 'pia@a.test');
update public.people set user_id = '00000000-0000-0000-0000-000000000021' where id = '20000000-0000-0000-0000-000000000021';  -- Pia can sign in
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
select public.reserve_asset(current_setting('app.smoke_asset')::uuid, '20000000-0000-0000-0000-000000000021', null);  -- Pia
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000021';  -- Pia: no it.* capability
set role authenticated;
do $$
begin
  assert (select count(*) from public.assets where asset_tag = 'LT-001') = 1, 'the holder sees the asset reserved for them';
  assert (select count(*) from public.asset_assignments where asset_id = current_setting('app.smoke_asset')::uuid and returned_at is null) = 1,
    'and the open assignment';
end $$;
reset role;
-- Bea (Company B) sees nothing of A's equipment and cannot work it.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  assert (select count(*) from public.assets where asset_tag = 'LT-001') = 0, 'other-company IT sees no assets';
  begin
    perform public.cancel_reservation((select id from public.asset_assignments where asset_id = current_setting('app.smoke_asset')::uuid));
    raise exception 'FAIL: worked an assignment across companies';
  exception when insufficient_privilege or raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    perform public.reserve_asset(current_setting('app.smoke_asset')::uuid, '20000000-0000-0000-0000-000000000005', null);
    raise exception 'FAIL: reserved across companies';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- ------------------------------------------------- payroll preparation (0023)
-- Fiona (Finance, A) gets payroll.individual and prepares; Alex gets
-- payroll.approve + payroll.export. Lines snapshot what is in force per day
-- of the period, in the period's currency; the preparer never approves.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000002', 'payroll.individual'),
  ('40000000-0000-0000-0000-000000000001', 'payroll.summary'),
  ('40000000-0000-0000-0000-000000000001', 'payroll.individual'),
  ('40000000-0000-0000-0000-000000000001', 'payroll.approve'),
  ('40000000-0000-0000-0000-000000000001', 'payroll.export')
on conflict do nothing;
insert into public.compensation_records (employment_period_id, amount, currency, pay_basis_key, effective_date, status) values
  ('30000000-0000-0000-0000-000000000022', 3000, 'USD', 'monthly', '2025-01-01', 'approved');   -- Quinn, paid in USD
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona
set role authenticated;
do $$
declare r jsonb; v_id uuid; n int;
begin
  r := public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date - 10, current_date + 70, 'eur', ' September run ');
  v_id := (r->>'period_id')::uuid;
  assert (select status from public.payroll_periods where id = v_id) = 'in_review', 'prepared periods await review';
  assert (select currency from public.payroll_periods where id = v_id) = 'EUR', 'currency upper-cased';
  assert (select note from public.payroll_periods where id = v_id) = 'September run', 'note trimmed';
  assert (select prepared_by from public.payroll_periods where id = v_id) = '20000000-0000-0000-0000-000000000002', 'prepared by Fiona';
  -- Alex: 60000 until yesterday, 66000 from today (0017); Pia: 1000 monthly, 1200 from day +60 (0020).
  assert (select count(*) from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000001') = 2,
    'a mid-period change gives two lines';
  assert (select days_covered from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000001' and amount = 60000) = 10,
    'the old rate covers the days before the change';
  assert (select days_covered from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000001' and amount = 66000) = 71,
    'the new rate covers the rest';
  assert (select days_covered from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000021' and amount = 1200) = 11,
    'a scheduled raise inside the period is included from its date';
  assert not exists (select 1 from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000022'),
    'a USD record is not in a EUR period';
  assert (r->>'uncovered')::int >= 1, 'people without a line in this currency are counted';
  -- Preparing again re-snapshots the same period.
  r := public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date - 10, current_date + 70, 'EUR', null);
  assert (r->>'period_id')::uuid = v_id, 'same range, same period';
  assert (select count(*) from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000001') = 2, 'lines rebuilt, not duplicated';
  -- The USD period covers Quinn until her employment ends.
  r := public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date - 10, current_date + 70, 'USD', null);
  assert (select days_covered from public.payroll_lines where period_id = (r->>'period_id')::uuid and person_id = '20000000-0000-0000-0000-000000000022') = 21,
    'a period ending inside the range is clamped to the employment end';
  begin
    perform public.approve_payroll_period(v_id);
    raise exception 'FAIL: the preparer approved their own period';
  exception when insufficient_privilege then null;
  end;
  update public.payroll_periods set status = 'approved' where id = v_id;
  get diagnostics n = row_count;
  assert n = 0 and (select status from public.payroll_periods where id = v_id) = 'in_review', 'a prepared period is not edited directly';
  delete from public.payroll_periods where id = v_id;
  get diagnostics n = row_count;
  assert n = 0, 'a prepared period is not deleted';
  begin
    perform public.mark_payroll_exported(v_id);
    raise exception 'FAIL: exported without payroll.export';
  exception when insufficient_privilege or raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare v_id uuid := (select id from public.payroll_periods where company_id = '10000000-0000-0000-0000-00000000000a' and currency = 'EUR' and period_start = current_date - 10);
begin
  begin
    perform public.mark_payroll_exported(v_id);
    raise exception 'FAIL: exported before approval';
  exception when raise_exception then
    if sqlerrm not like '%Only an approved period%' then raise; end if;
  end;
  perform public.approve_payroll_period(v_id);
  assert (select approved_by from public.payroll_periods where id = v_id) = '20000000-0000-0000-0000-000000000001', 'approved by Alex';
  begin
    perform public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date - 10, current_date + 70, 'EUR', null);
    raise exception 'FAIL: re-prepared an approved period';
  exception when raise_exception then
    if sqlerrm not like '%already approved%' then raise; end if;
  end;
  perform public.mark_payroll_exported(v_id);
  assert (select status from public.payroll_periods where id = v_id) = 'exported', 'exported';
  assert (select exported_at from public.payroll_periods where id = v_id) is not null, 'with a timestamp';
  begin
    perform public.reopen_payroll_period(v_id);
    raise exception 'FAIL: reopened an exported period';
  exception when raise_exception then
    if sqlerrm not like '%Only an approved period%' then raise; end if;
  end;
  assert not exists (select 1 from public.activity_log where entity_type = 'payroll_lines' and coalesce(after, '{}') ? 'amount'),
    'line amounts are not in the audit trail';
end $$;
reset role;
-- Omar (no payroll capability) and Bea (Company B) see nothing.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  assert (select count(*) from public.payroll_periods) = 0, 'no payroll.summary, no periods';
  assert (select count(*) from public.payroll_lines) = 0, 'no payroll.individual, no lines';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  assert (select count(*) from public.payroll_lines) = 0, 'other-company HR sees no lines';
  begin
    perform public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date, current_date + 1, 'EUR', null);
    raise exception 'FAIL: prepared payroll across companies';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- ------------------------------------------------------ people import (0024)
-- Alex (employment.edit in A) previews and imports; a refused row blocks the
-- whole file; managers resolve inside the file or to people employed here.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
declare r jsonb; n_before int; v_ivan uuid; v_jana uuid;
begin
  n_before := (select count(*) from public.people);
  r := public.import_people('10000000-0000-0000-0000-00000000000a', '[
    {"full_name":"Ivan Import","work_email":"IVAN@a.test","job_title":"Analyst","start_date":"2024-02-01","department":"shared finance","manager_email":"alex@a.test","employment_type_key":"full_time"},
    {"full_name":"Jana Import","work_email":"jana@a.test","job_title":"Junior Analyst","start_date":"2999-01-01","manager_email":"ivan@a.test"},
    {"full_name":"Omar Again","work_email":"omar@a.test","job_title":"Engineer","start_date":"2024-01-01"},
    {"full_name":"X","work_email":"not-an-email","job_title":"","start_date":"soon","department":"Nowhere","manager_email":"ghost@a.test"}
  ]'::jsonb, false);
  assert (r->>'committed')::boolean = false and (r->>'ready')::int = 2 and (r->>'refused')::int = 2, 'preview counts';
  assert (select count(*) from public.people) = n_before, 'a preview writes nothing';
  assert (r->'rows'->2->'problems')::text like '%already exists%', 'an existing email is refused, never merged';
  assert jsonb_array_length(r->'rows'->3->'problems') >= 5, 'every problem of a bad row is listed';
  assert (r->'rows'->3->'problems')::text like '%neither in the file nor employed%', 'unknown manager named';
  begin
    perform public.import_people('10000000-0000-0000-0000-00000000000a', '[
      {"full_name":"Ivan Import","work_email":"ivan@a.test","job_title":"Analyst","start_date":"2024-02-01"},
      {"full_name":"Omar Again","work_email":"omar@a.test","job_title":"Engineer","start_date":"2024-01-01"}
    ]'::jsonb, true);
    raise exception 'FAIL: committed a file with a refused row';
  exception when raise_exception then
    if sqlerrm not like '%not ready%' then raise; end if;
  end;
  assert (select count(*) from public.people) = n_before, 'a refused commit writes nothing';

  r := public.import_people('10000000-0000-0000-0000-00000000000a', '[
    {"full_name":"Ivan Import","work_email":"IVAN@a.test","job_title":"Analyst","start_date":"2024-02-01","department":"shared finance","manager_email":"alex@a.test","employment_type_key":"full_time"},
    {"full_name":"Jana Import","work_email":"jana@a.test","job_title":"Junior Analyst","start_date":"2999-01-01","manager_email":"ivan@a.test"}
  ]'::jsonb, true);
  assert (r->>'committed')::boolean = true, 'committed';
  assert (select count(*) from public.people) = n_before + 2, 'two people written';
  v_ivan := (select id from public.people where work_email = 'ivan@a.test');
  v_jana := (select id from public.people where work_email = 'jana@a.test');
  assert (select status from public.employment_periods where person_id = v_ivan) = 'active', 'started in the past: active';
  assert (select status from public.employment_periods where person_id = v_jana) = 'pre_start', 'future start: pre-start';
  assert (select manager_id from public.employment_periods where person_id = v_ivan) = '20000000-0000-0000-0000-000000000001', 'manager already employed here';
  assert (select manager_id from public.employment_periods where person_id = v_jana) = v_ivan, 'manager from the file';
  assert (select department_id from public.employment_periods where person_id = v_ivan) = 'e0000000-0000-0000-0000-000000000000', 'shared department by name, case-insensitive';
  assert (select employment_type_key from public.employment_periods where person_id = v_ivan) = 'full_time', 'employment type kept';
  r := public.import_people('10000000-0000-0000-0000-00000000000a', '[
    {"full_name":"Ivan Import","work_email":"Ivan@A.Test","job_title":"Analyst","start_date":"2024-02-01"}
  ]'::jsonb, false);
  assert (r->>'refused')::int = 1, 'a second import of the same email is refused whatever the case';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea: no employment.edit in A
set role authenticated;
do $$
begin
  begin
    perform public.import_people('10000000-0000-0000-0000-00000000000a', '[{"full_name":"Zed","work_email":"zed@a.test","job_title":"x","start_date":"2024-01-01"}]'::jsonb, true);
    raise exception 'FAIL: imported across companies';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- ------------------------------------- equipment on offboarding (0025)
-- Pia holds LT-001 (reserved in the 0022 block). Scheduling her departure
-- adds a return task; taking the asset back completes it; re-scheduling
-- adds tasks for equipment handed out since; a leaver with nothing on
-- hand gets no equipment task.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'departure.start')
on conflict do nothing;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare r jsonb; v_plan uuid; v_task uuid; v_asset2 uuid; v_a2 uuid;
begin
  r := public.schedule_departure('30000000-0000-0000-0000-000000000021', current_date + 30, current_date + 28, null);
  v_plan := (r->>'plan_id')::uuid;
  select id into v_task from public.plan_tasks where plan_id = v_plan and asset_id = current_setting('app.smoke_asset')::uuid;
  assert v_task is not null, 'a return task for the held asset';
  assert (select title from public.plan_tasks where id = v_task) like 'Return LT-001 · Laptop%', 'named after the asset';
  assert (select owner_role from public.plan_tasks where id = v_task) = 'it', 'owned by IT';
  assert (select critical from public.plan_tasks where id = v_task), 'critical';
  assert (select due_date from public.plan_tasks where id = v_task) = current_date + 28, 'due on the last working day';
  perform public.cancel_reservation((select id from public.asset_assignments where asset_id = current_setting('app.smoke_asset')::uuid and returned_at is null));
  assert (select status from public.plan_tasks where id = v_task) = 'done', 'taking it back completes the task';
  assert (select done_by from public.plan_tasks where id = v_task) = '20000000-0000-0000-0000-000000000001', 'by whoever took it back';
  -- Equipment handed out after scheduling: re-scheduling adds its task.
  insert into public.assets (company_id, asset_tag, type_key) values ('10000000-0000-0000-0000-00000000000a', 'PH-001', 'phone') returning id into v_asset2;
  r := public.reserve_asset(v_asset2, '20000000-0000-0000-0000-000000000021', null);
  v_a2 := (r->>'assignment_id')::uuid;
  perform public.issue_asset(v_a2);
  r := public.schedule_departure('30000000-0000-0000-0000-000000000021', current_date + 40, current_date + 38, null);
  assert (r->>'already_scheduled')::boolean, 'same plan';
  assert (select start_date from public.plans where id = v_plan) = current_date + 38, 'the plan follows the new last day';
  assert exists (select 1 from public.plan_tasks where plan_id = v_plan and asset_id = v_asset2 and status = 'open' and due_date = current_date + 38), 'a task for the phone, due on the new last day';
  assert (select count(*) from public.plan_tasks where plan_id = v_plan and asset_id = current_setting('app.smoke_asset')::uuid) = 1, 'no duplicate for the laptop';
  perform public.return_asset(v_a2, 'fine', 'available');
  assert (select status from public.plan_tasks where plan_id = v_plan and asset_id = v_asset2) = 'done', 'returning completes it too';
  -- Quinn holds nothing.
  r := public.schedule_departure('30000000-0000-0000-0000-000000000022', current_date + 9, null, null);
  assert not exists (select 1 from public.plan_tasks where plan_id = (r->>'plan_id')::uuid and asset_id is not null), 'no equipment task without equipment';
end $$;
reset role;
set app.test_uid = '';

-- ------------------------------------------------- company structure (0026)
-- Alex gets employment.edit in B as well. Rhea moves from A to B today;
-- Sven moves next week; a company with people cannot be archived, an empty
-- one can, the holding never.
insert into public.people (id, full_name) values
  ('20000000-0000-0000-0000-000000000023', 'Rhea Relocate'),
  ('20000000-0000-0000-0000-000000000024', 'Sven Soon');
insert into public.employment_periods (id, person_id, company_id, job_title, employment_type_key, status, start_date) values
  ('30000000-0000-0000-0000-000000000025', '20000000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-00000000000a', 'Accountant', 'full_time', 'active', '2024-01-01'),
  ('30000000-0000-0000-0000-000000000026', '20000000-0000-0000-0000-000000000024', '10000000-0000-0000-0000-00000000000a', 'Designer', 'part_time', 'active', '2024-01-01');
insert into public.companies (id, kind, name, short_code, archived_at) values
  ('10000000-0000-0000-0000-00000000000c', 'company', 'Company C (closed)', 'C', now()),
  ('10000000-0000-0000-0000-00000000000d', 'company', 'Company D (empty)', 'D', null),
  ('10000000-0000-0000-0000-00000000000e', 'holding', 'The Holding', 'HOLD', null);
insert into public.access_grants (id, person_id, company_id) values
  ('40000000-0000-0000-0000-000000000026', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000b');
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000026', 'people.view'),
  ('40000000-0000-0000-0000-000000000026', 'employment.edit');
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare r jsonb; v_new uuid;
begin
  begin
    perform public.transfer_employment('30000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-00000000000c', current_date);
    raise exception 'FAIL: transferred into an archived company';
  exception when raise_exception then
    if sqlerrm not like '%not available%' then raise; end if;
  end;
  begin
    perform public.transfer_employment('30000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-00000000000a', current_date);
    raise exception 'FAIL: transferred into the same company';
  exception when raise_exception then
    if sqlerrm not like '%already works for%' then raise; end if;
  end;
  begin
    perform public.transfer_employment('30000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-00000000000b', '2024-01-01');
    raise exception 'FAIL: transfer dated on the start date accepted';
  exception when raise_exception then
    if sqlerrm not like '%after the employment started%' then raise; end if;
  end;
  begin
    perform public.transfer_employment('30000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-00000000000d', current_date);
    raise exception 'FAIL: transferred without employment.edit in the target';
  exception when insufficient_privilege then null;
  end;
  -- Today: the old period ends yesterday and is former, the new one is active.
  r := public.transfer_employment('30000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-00000000000b', current_date, null, null, 'Moves with the finance function');
  v_new := (r->>'new_period_id')::uuid;
  assert (r->>'applied')::boolean, 'applied at once';
  assert (select status from public.employment_periods where id = '30000000-0000-0000-0000-000000000025') = 'former', 'old period former';
  assert (select end_date from public.employment_periods where id = '30000000-0000-0000-0000-000000000025') = current_date - 1, 'ended the day before';
  assert (select last_working_date from public.employment_periods where id = '30000000-0000-0000-0000-000000000025') = current_date - 1, 'last day the day before';
  assert (select transferred_to_period_id from public.employment_periods where id = '30000000-0000-0000-0000-000000000025') = v_new, 'linked';
  assert (select status from public.employment_periods where id = v_new) = 'active', 'new period active';
  assert (select company_id from public.employment_periods where id = v_new) = '10000000-0000-0000-0000-00000000000b', 'at the target';
  assert (select job_title || '/' || employment_type_key from public.employment_periods where id = v_new) = 'Accountant/full_time', 'title and type carried';
  assert (select start_date from public.employment_periods where id = v_new) = current_date, 'starts on the date';
  assert not exists (select 1 from public.plans where employment_period_id = '30000000-0000-0000-0000-000000000025'), 'a transfer is not a departure: no plan';
  assert exists (select 1 from public.employment_changes where employment_period_id = v_new and reason = 'Moves with the finance function' and status = 'applied'), 'the reason is on record';
  begin
    perform public.transfer_employment('30000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-00000000000b', current_date);
    raise exception 'FAIL: transferred an ended period';
  exception when raise_exception then
    if sqlerrm not like '%has ended%' then raise; end if;
  end;
  -- Next week: old stays active until the day, new waits as pre-start.
  r := public.transfer_employment('30000000-0000-0000-0000-000000000026', '10000000-0000-0000-0000-00000000000b', current_date + 7, 'Senior Designer', null, null);
  assert not (r->>'applied')::boolean, 'a future transfer waits';
  assert (select status from public.employment_periods where id = '30000000-0000-0000-0000-000000000026') = 'active', 'old still active';
  assert (select end_date from public.employment_periods where id = '30000000-0000-0000-0000-000000000026') = current_date + 6, 'old ends the day before';
  assert (select status || '/' || job_title from public.employment_periods where id = (r->>'new_period_id')::uuid) = 'pre_start/Senior Designer', 'new pre-start with the new title';
  begin
    perform public.transfer_employment('30000000-0000-0000-0000-000000000026', '10000000-0000-0000-0000-00000000000b', current_date + 8);
    raise exception 'FAIL: second transfer scheduled on the same period';
  exception when raise_exception then
    if sqlerrm not like '%already scheduled%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '';
-- The day arrives (simulated): the nightly job completes the transfer.
update public.employment_periods set end_date = current_date - 2, last_working_date = current_date - 2 where id = '30000000-0000-0000-0000-000000000026';
update public.employment_periods set start_date = current_date - 1 where person_id = '20000000-0000-0000-0000-000000000024' and status = 'pre_start';
do $$
begin
  perform public.apply_due_employment_changes();
  assert (select status from public.employment_periods where id = '30000000-0000-0000-0000-000000000026') = 'former', 'old period completed on the day';
  assert (select status from public.employment_periods where person_id = '20000000-0000-0000-0000-000000000024' and company_id = '10000000-0000-0000-0000-00000000000b') = 'active', 'new period started';
end $$;
-- Archiving.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada, admin
set role authenticated;
do $$
declare r jsonb;
begin
  begin
    perform public.archive_company('10000000-0000-0000-0000-00000000000b');
    raise exception 'FAIL: archived a company with people';
  exception when raise_exception then
    if sqlerrm not like '%people are still employed here%' then raise; end if;
  end;
  begin
    perform public.archive_company('10000000-0000-0000-0000-00000000000e');
    raise exception 'FAIL: archived the holding';
  exception when raise_exception then
    if sqlerrm not like '%holding cannot be archived%' then raise; end if;
  end;
  r := public.archive_company('10000000-0000-0000-0000-00000000000d');
  assert (r->>'archived')::boolean and not (r->>'already')::boolean, 'an empty company archives';
  r := public.archive_company('10000000-0000-0000-0000-00000000000c');
  assert (r->>'already')::boolean, 'archiving twice is a no-op';
  begin
    update public.companies set archived_at = now() where id = '10000000-0000-0000-0000-00000000000b';
    raise exception 'FAIL: direct archive slipped past the guard';
  exception when raise_exception then
    if sqlerrm not like '%still employed here%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '';

-- 0026 review fixes: a scheduled departure blocks a transfer; a change due
-- before the move applies to the old employment first.
insert into public.people (id, full_name) values
  ('20000000-0000-0000-0000-000000000027', 'Tara Leaving'),
  ('20000000-0000-0000-0000-000000000028', 'Uma Upgraded');
insert into public.employment_periods (id, person_id, company_id, job_title, status, start_date) values
  ('30000000-0000-0000-0000-000000000027', '20000000-0000-0000-0000-000000000027', '10000000-0000-0000-0000-00000000000a', 'Clerk', 'active', '2024-01-01'),
  ('30000000-0000-0000-0000-000000000028', '20000000-0000-0000-0000-000000000028', '10000000-0000-0000-0000-00000000000a', 'Junior', 'active', '2024-01-01');
insert into public.employment_changes (employment_period_id, company_id, effective_date, changes, status)
  values ('30000000-0000-0000-0000-000000000028', '10000000-0000-0000-0000-00000000000a', current_date - 1, '{"job_title":"Senior"}', 'scheduled');
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare r jsonb;
begin
  perform public.schedule_departure('30000000-0000-0000-0000-000000000027', current_date + 20, null, null);
  begin
    perform public.transfer_employment('30000000-0000-0000-0000-000000000027', '10000000-0000-0000-0000-00000000000b', current_date + 5);
    raise exception 'FAIL: transferred an employment with a scheduled departure';
  exception when raise_exception then
    if sqlerrm not like '%departure is already scheduled%' then raise; end if;
  end;
  r := public.transfer_employment('30000000-0000-0000-0000-000000000028', '10000000-0000-0000-0000-00000000000b', current_date);
  assert (select job_title from public.employment_periods where id = '30000000-0000-0000-0000-000000000028') = 'Senior', 'the due change applied to the old employment first';
  assert (select job_title from public.employment_periods where id = (r->>'new_period_id')::uuid) = 'Senior', 'and the new one carries the applied title';
  assert (select status from public.employment_changes where employment_period_id = '30000000-0000-0000-0000-000000000028') = 'applied', 'not cancelled';
end $$;
reset role;
set app.test_uid = '';

-- ------------------------------------------------------------- leave (0027)
-- Alex (A) gets the leave capabilities; Pia (A, signed in as …21) is the
-- employee. Company A follows the MK calendar and closes for one day.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000001', 'leave.view'),
  ('40000000-0000-0000-0000-000000000001', 'leave.approve'),
  ('40000000-0000-0000-0000-000000000001', 'leave.adjust'),
  ('40000000-0000-0000-0000-000000000001', 'holidays.manage')
on conflict do nothing;
update public.companies set country_code = 'MK' where id = '10000000-0000-0000-0000-00000000000a';
update public.employment_periods set end_date = null, last_working_date = null, status = 'active', transferred_to_period_id = null
  where id = '30000000-0000-0000-0000-000000000021';   -- Pia stays (the 0025 departure test is over)
delete from public.plans where employment_period_id = '30000000-0000-0000-0000-000000000021';
insert into public.public_holidays (country_code, date, name) values ('MK', '2027-03-03', 'Test holiday');
insert into public.company_closures (company_id, date, name) values ('10000000-0000-0000-0000-00000000000a', '2027-03-04', 'Team building');
do $$
begin
  assert app.working_days('2027-03-01', '2027-03-07', 'MK', '10000000-0000-0000-0000-00000000000a') = 3,
    'a week minus the weekend, a holiday and a closure';
  assert app.working_days('2027-03-01', '2027-03-07', 'RS', '10000000-0000-0000-0000-00000000000a') = 4,
    'another country does not get the MK holiday';
  assert app.working_days('2027-03-01', '2027-03-07', 'MK', '10000000-0000-0000-0000-00000000000b') = 4,
    'another company does not get the closure';
  assert app.employment_country('30000000-0000-0000-0000-000000000021') = 'MK', 'country from the company when there is no location';
end $$;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
select public.set_leave_entitlement('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027, 20, 'Standard entitlement');
reset role;
update public.leave_balances set carry_over_days = 4 where person_id = '20000000-0000-0000-0000-000000000021' and year = 2027;
set app.test_uid = '00000000-0000-0000-0000-000000000021';  -- Pia
set role authenticated;
do $$
declare r jsonb; v_first uuid; v_second uuid; b jsonb;
begin
  r := public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-03-01', '2027-03-07', 'Skiing');
  v_first := (r->>'request_id')::uuid;
  assert (r->>'working_days')::int = 3 and r->>'status' = 'pending', 'three working days, pending';
  begin
    perform public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-03-02', '2027-03-02');
    raise exception 'FAIL: overlapping request accepted';
  exception when raise_exception then
    if sqlerrm not like '%already requested%' then raise; end if;
  end;
  r := public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-03-08', '2027-03-12');
  v_second := (r->>'request_id')::uuid;
  assert (r->>'working_days')::int = 5, 'five working days';
  begin
    perform public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-08-02', '2027-08-20');   -- 15 days
    raise exception 'FAIL: request beyond the requestable balance accepted';
  exception when raise_exception then
    if sqlerrm not like '%Not enough annual leave%' then raise; end if;
  end;
  begin
    perform public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-12-30', '2028-01-03');
    raise exception 'FAIL: annual leave across two years accepted';
  exception when raise_exception then
    if sqlerrm not like '%per leave year%' then raise; end if;
  end;
  begin
    perform public.request_leave('20000000-0000-0000-0000-000000000021', 'sick', '2027-04-05', '2027-04-06');
    raise exception 'FAIL: sick leave without a document or a promise accepted';
  exception when raise_exception then
    if sqlerrm not like '%supporting document%' then raise; end if;
  end;
  r := public.request_leave('20000000-0000-0000-0000-000000000021', 'sick', '2027-04-05', '2027-04-06', null, true);
  assert r->>'status' = 'pending', 'sick leave with a promise is filed';
  begin
    perform public.request_leave('20000000-0000-0000-0000-000000000001', 'annual', '2027-05-03', '2027-05-04');
    raise exception 'FAIL: filed leave for someone else';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.decide_leave(v_first, 'approved');
    raise exception 'FAIL: decided own leave';
  exception when insufficient_privilege then null;
  end;
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027);
  assert (b->>'pending')::numeric = 8 and (b->>'remaining')::numeric = 20, 'pending reserves, nothing used yet';
  -- Self-cancel before it starts.
  perform public.cancel_leave(v_second, 'Plans changed');
  assert (select status from public.leave_requests where id = v_second) = 'cancelled', 'cancelled by the owner';
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027);
  assert (b->>'pending')::numeric = 3, 'the cancelled request no longer reserves';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex decides
set role authenticated;
do $$
declare v_first uuid := (select id from public.leave_requests where person_id = '20000000-0000-0000-0000-000000000021' and start_date = '2027-03-01');
        r jsonb; b jsonb;
begin
  r := public.decide_leave(v_first, 'approved', 'Enjoy');
  assert (r->>'carry_over_days_used')::int = 3, 'March days draw the carry-over first';
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027);
  assert (b->>'remaining')::numeric = 20 and (b->>'carry_over_remaining')::numeric = 1 and (b->>'used')::numeric = 0,
    'entitlement untouched, one carry-over day left';
  -- Recording something agreed: approver files and approves at once, after the window.
  r := public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-08-02', '2027-08-03', 'Agreed verbally', false, true);
  assert r->>'status' = 'approved', 'filed as approved';
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027);
  assert (b->>'remaining')::numeric = 18 and (b->>'carry_over_remaining')::numeric = 1, 'August days come from the year, not the expired window';
  begin
    perform public.decide_leave(v_first, 'rejected');
    raise exception 'FAIL: decided an already approved request';
  exception when raise_exception then
    if sqlerrm not like '%Only a pending%' then raise; end if;
  end;
  -- Adjustments.
  begin
    perform public.adjust_leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027, -30, 'Oops');
    raise exception 'FAIL: adjusted below zero';
  exception when raise_exception then
    if sqlerrm not like '%below zero%' then raise; end if;
  end;
  perform public.adjust_leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027, 2, 'Worked a holiday');
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027);
  assert (b->>'remaining')::numeric = 20, 'adjustment adds two days';
end $$;
reset role;
-- Leave that has started: the owner must ask; HR declines, the ask is repeated, HR cancels.
set app.test_uid = '';
insert into public.leave_requests (id, person_id, employment_period_id, company_id, leave_type_key, deducts_balance, requires_document, start_date, end_date, working_days, status)
  values ('a1000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000021', '30000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a',
          'annual', true, false, current_date - 2, current_date + 2, 3, 'approved');
set app.test_uid = '00000000-0000-0000-0000-000000000021';  -- Pia
set role authenticated;
do $$
begin
  begin
    perform public.cancel_leave('a1000000-0000-0000-0000-000000000001', 'Came back early');
    raise exception 'FAIL: cancelled started leave herself';
  exception when raise_exception then
    if sqlerrm not like '%has started%' then raise; end if;
  end;
  perform public.request_leave_cancellation('a1000000-0000-0000-0000-000000000001', 'I returned to work early');
  assert (select cancellation_requested_at from public.leave_requests where id = 'a1000000-0000-0000-0000-000000000001') is not null, 'asked';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
begin
  perform public.decline_leave_cancellation('a1000000-0000-0000-0000-000000000001', 'The days were already paid out');
  assert (select cancellation_declined_at from public.leave_requests where id = 'a1000000-0000-0000-0000-000000000001') is not null, 'declined';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000021';
set role authenticated;
select public.request_leave_cancellation('a1000000-0000-0000-0000-000000000001', 'Please check again');
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  assert (select cancellation_declined_at from public.leave_requests where id = 'a1000000-0000-0000-0000-000000000001') is null, 'asking again clears the decline';
  perform public.cancel_leave('a1000000-0000-0000-0000-000000000001', 'Confirmed: back at work');
  assert (select status from public.leave_requests where id = 'a1000000-0000-0000-0000-000000000001') = 'cancelled', 'HR cancelled it';
end $$;
reset role;
-- Colleagues see that Pia is away, never why; HR sees the type.
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar: in A by grant, no leave capability
set role authenticated;
do $$
declare t jsonb;
begin
  t := public.team_leave('10000000-0000-0000-0000-00000000000a', '2027-03-01', '2027-03-31');
  assert jsonb_array_length(t) >= 1, 'the calendar shows the absence';
  assert (t->0->>'leave_type_key') = 'away' and (t->0->>'note') is null, 'redacted for a colleague';
  assert (select count(*) from public.leave_requests) = 0, 'no direct read of colleagues'' requests';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
declare t jsonb;
begin
  t := public.team_leave('10000000-0000-0000-0000-00000000000a', '2027-03-01', '2027-03-31');
  assert (t->0->>'leave_type_key') = 'annual' and (t->0->>'note') = 'Skiing', 'HR sees the type and note';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea: Company B
set role authenticated;
do $$
begin
  assert (select count(*) from public.leave_requests) = 0, 'other-company HR sees nothing';
  begin
    perform public.team_leave('10000000-0000-0000-0000-00000000000a', '2027-03-01', '2027-03-31');
    raise exception 'FAIL: read another company''s calendar';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';
-- Rollover: next year's row per current employment, idempotent.
do $$
declare n int; b jsonb;
begin
  n := public.roll_leave_year(2028);
  assert n >= 1, 'rolled at least Pia';
  assert public.roll_leave_year(2028) = 0, 'a second run adds nothing';
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2028);
  assert (b->>'entitlement')::numeric = 20 and (b->>'carry_over')::numeric = 20,
    'entitlement carried; the remainder carries over, the old carry-over does not (its window ended in June)';
  assert (b->>'carry_over_expires_on') = '2028-06-30', 'expires per the company rule';
end $$;

reset role;
set app.test_uid = '';

-- ================================================================ 0029
-- Sick-leave certificates: the pending sick request Pia filed with a promise
-- opens her self-upload window for medical_certificate (and nothing else);
-- attaching the document closes it.
set app.test_uid = '00000000-0000-0000-0000-000000000021';
set role authenticated;
do $$
declare v_req uuid; v_doc uuid;
begin
  select id into v_req from public.leave_requests
    where person_id = '20000000-0000-0000-0000-000000000021' and leave_type_key = 'sick' and status = 'pending' limit 1;
  assert v_req is not null, 'the sick request from the 0027 block is still pending';
  assert app.has_open_document_request('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 'medical_certificate'), 'window open for a certificate';
  assert not app.has_open_document_request('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 'identification'), 'only for certificates';
  begin
    insert into public.documents (company_id, person_id, category_key, title, storage_path)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000021', 'identification', 'Sneaky', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000021/sneaky.pdf');
    raise exception 'FAIL: self upload outside the window';
  exception when insufficient_privilege then null;
  end;
  insert into public.documents (company_id, person_id, category_key, title, storage_path)
  values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000021', 'medical_certificate', 'Certificate April', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000021/cert-april.pdf')
  returning id into v_doc;
  assert app.self_certificate_window('10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000021/cert-april.pdf'), 'storage insert window open';
  assert not app.self_document_window('10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000021/cert-april.pdf'), 'the HR-request (delete) window stays closed';
  perform public.attach_leave_document(v_req, v_doc);
  assert (select count(*) from public.leave_request_documents where request_id = v_req) = 1, 'attached';
  assert not app.has_open_document_request('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 'medical_certificate'), 'window closes once attached';
  assert not app.self_certificate_window('10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000021/cert-may.pdf'), 'storage window closes too';
  -- Preview arithmetic is the server's (the earlier blocks left Pia with 20 and nothing pending that deducts).
  assert public.requestable_leave('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', '2027-09-06', '2027-09-10')
    = (public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027)->>'remaining')::numeric
    - (public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027)->>'pending')::numeric,
    'requestable = remaining minus pending: ' || public.requestable_leave('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', '2027-09-06', '2027-09-10');
  begin
    perform public.requestable_leave('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', '2027-09-06', '2027-09-10');
    raise exception 'FAIL: previewed a colleague''s balance without leave.view';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- ================================================================ 0031
-- Profile photos: a person sets their own, someone who may edit their record
-- may too, anyone else is refused, and the path must sit in the person's
-- own folder. The storage policy helper answers the same way.
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar, no grants
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.set_avatar('20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003/a1b2.webp');
  assert r->>'avatar_url' = '20000000-0000-0000-0000-000000000003/a1b2.webp', 'own photo set';
  assert (select avatar_url from public.people where id = '20000000-0000-0000-0000-000000000003') = '20000000-0000-0000-0000-000000000003/a1b2.webp', 'stored on the record';
  assert app.can_write_avatar('20000000-0000-0000-0000-000000000003/a1b2.webp'), 'may write own folder';
  assert not app.can_write_avatar('20000000-0000-0000-0000-000000000002/x.webp'), 'not a colleague''s folder';
  assert not app.can_write_avatar('junk/x.webp'), 'not a junk folder';
  begin
    perform public.set_avatar('20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002/x.webp');
    raise exception 'FAIL: photo stored under another person''s folder';
  exception when raise_exception then
    if sqlerrm not like '%own folder%' then raise; end if;
  end;
  begin
    perform public.set_avatar('20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002/x.webp');
    raise exception 'FAIL: changed a colleague''s photo without edit rights';
  exception when insufficient_privilege then null;
  end;
  r := public.set_avatar('20000000-0000-0000-0000-000000000003', null);
  assert r->>'previous' = '20000000-0000-0000-0000-000000000003/a1b2.webp' and (r->>'avatar_url') is null, 'cleared, previous path returned for cleanup';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada, platform admin
set role authenticated;
do $$
begin
  perform public.set_avatar('20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003/by-hr.webp');
  assert (select avatar_url from public.people where id = '20000000-0000-0000-0000-000000000003') = '20000000-0000-0000-0000-000000000003/by-hr.webp', 'HR may set it';
  assert app.can_write_avatar('20000000-0000-0000-0000-000000000003/by-hr.webp'), 'and write the folder';
end $$;
reset role;
set app.test_uid = '';

-- ================================================================ 0032
-- Correcting approved leave: only approvers (never their own, unless admin),
-- only approved rows, working days only, no overlap; the balance follows
-- both ways; a mix of types splits the leave; every correction is recorded.
set app.test_uid = '00000000-0000-0000-0000-000000000021';  -- Pia, the owner
set role authenticated;
do $$
declare v_aug uuid := (select id from public.leave_requests where person_id = '20000000-0000-0000-0000-000000000021' and start_date = '2027-08-02');
begin
  assert v_aug is not null, 'Pia''s August leave from the 0027 block is there';
  begin
    perform public.correct_leave(v_aug, '[{"date":"2027-08-02","leave_type_key":"annual"}]'::jsonb, 'Shorter');
    raise exception 'FAIL: the owner corrected their own leave without leave.approve';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex approves in A
set role authenticated;
do $$
declare
  v_aug uuid := (select id from public.leave_requests where person_id = '20000000-0000-0000-0000-000000000021' and start_date = '2027-08-02');
  v_mar uuid := (select id from public.leave_requests where person_id = '20000000-0000-0000-0000-000000000021' and start_date = '2027-03-01');
  r jsonb; b jsonb; c record;
  v_before numeric := (public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027)->>'remaining')::numeric;
begin
  -- Refusals first: a weekend day, a day another leave covers, a pending/cancelled row.
  begin
    perform public.correct_leave(v_aug, '[{"date":"2027-08-07","leave_type_key":"annual"}]'::jsonb);
    raise exception 'FAIL: corrected onto a Saturday';
  exception when raise_exception then
    if sqlerrm not like '%not a working day%' then raise; end if;
  end;
  begin
    perform public.correct_leave(v_aug, '[{"date":"2027-03-01","leave_type_key":"annual"}]'::jsonb);
    raise exception 'FAIL: corrected onto dates the March leave covers';
  exception when raise_exception then
    if sqlerrm not like '%already covers%' then raise; end if;
  end;
  begin
    perform public.correct_leave(v_mar, '[]'::jsonb);
    raise exception 'FAIL: accepted an empty correction';
  exception when raise_exception then
    if sqlerrm not like '%at least one%' then raise; end if;
  end;
  -- Longer: 2 → 4 working days, two more taken from the year.
  r := public.correct_leave(v_aug, '[{"date":"2027-08-02","leave_type_key":"annual"},{"date":"2027-08-03","leave_type_key":"annual"},{"date":"2027-08-04","leave_type_key":"annual"},{"date":"2027-08-05","leave_type_key":"annual"}]'::jsonb, 'Stayed two more days');
  assert (r->>'working_days')::int = 4 and (r->>'deducting_before')::int = 2 and (r->>'deducting_after')::int = 4, 'longer: ' || r::text;
  assert jsonb_array_length(r->'split_request_ids') = 0, 'one type, no split';
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027);
  assert (b->>'remaining')::numeric = v_before - 2, 'two more days taken: ' || b::text;
  assert (select end_date || '/' || working_days from public.leave_requests where id = v_aug) = '2027-08-05/4', 'the row itself moved';
  select * into c from public.leave_corrections where request_id = v_aug order by corrected_at desc limit 1;
  assert c.old_end = '2027-08-03' and c.old_working_days = 2 and c.new_end = '2027-08-05' and c.new_working_days = 4
     and c.note = 'Stayed two more days' and c.corrected_by = '20000000-0000-0000-0000-000000000001', 'correction recorded';
  -- Mixed: Mon annual, Tue sick, Wed annual → three rows, one day given back to the year.
  r := public.correct_leave(v_aug, '[{"date":"2027-08-02","leave_type_key":"annual"},{"date":"2027-08-03","leave_type_key":"sick"},{"date":"2027-08-04","leave_type_key":"annual"}]'::jsonb, 'Tuesday was sick leave');
  assert jsonb_array_length(r->'split_request_ids') = 2, 'two rows split off: ' || r::text;
  assert (r->>'deducting_after')::int = 2, 'sick does not deduct';
  assert (select start_date || '/' || end_date || '/' || leave_type_key || '/' || working_days from public.leave_requests where id = v_aug) = '2027-08-02/2027-08-02/annual/1', 'the original keeps the first run';
  assert (select count(*) from public.leave_requests where corrected_from_id = v_aug and status = 'approved') = 2, 'split rows are approved and linked';
  assert (select leave_type_key || '/' || requires_document::text from public.leave_requests where corrected_from_id = v_aug and start_date = '2027-08-03') = 'sick/true', 'the sick day carries its type flags';
  b := public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027);
  assert (b->>'remaining')::numeric = v_before, 'back to two deducting days: ' || b::text;
  -- Too much: refused with what is available.
  begin
    perform public.correct_leave(v_aug, (select jsonb_agg(jsonb_build_object('date', d::date, 'leave_type_key', 'annual'))
      from generate_series('2027-09-06'::date, '2027-10-15'::date, '1 day') d where extract(isodow from d) < 6));
    raise exception 'FAIL: corrected past the balance';
  exception when raise_exception then
    if sqlerrm not like 'Not enough leave left%' then raise; end if;
  end;
  assert (public.leave_balance('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-00000000000a', 2027)->>'remaining')::numeric = v_before, 'a refused correction changes nothing';
end $$;
reset role;
-- Alex may not correct his own approved leave; Ada (platform admin) may.
set app.test_uid = '';
insert into public.leave_requests (id, person_id, employment_period_id, company_id, leave_type_key, deducts_balance, requires_document, start_date, end_date, working_days, status)
  values ('a1000000-0000-0000-0000-000000000032', '20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a',
          'other', false, false, '2027-09-06', '2027-09-07', 2, 'approved');
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  begin
    perform public.correct_leave('a1000000-0000-0000-0000-000000000032', '[{"date":"2027-09-06","leave_type_key":"other"}]'::jsonb);
    raise exception 'FAIL: corrected own leave';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
begin
  perform public.correct_leave('a1000000-0000-0000-0000-000000000032', '[{"date":"2027-09-06","leave_type_key":"other"}]'::jsonb, 'One day only');
  assert (select working_days from public.leave_requests where id = 'a1000000-0000-0000-0000-000000000032') = 1, 'admin corrected it';
end $$;
reset role;
set app.test_uid = '';

-- ================================================================ 0033
-- Hiring-request revisions: sending back needs jobs.approve and a reason,
-- never on one's own; the content locks once submitted; the requester
-- revises and resubmits (decision cleared); history records each step.
set app.test_uid = '';
insert into public.grant_capabilities (grant_id, capability_key) values ('40000000-0000-0000-0000-000000000002', 'jobs.request') on conflict do nothing;  -- Fiona may request hires
insert into public.hiring_requests (id, company_id, title, status, requested_by, headcount) values
  ('60000000-0000-0000-0000-000000000033', '10000000-0000-0000-0000-00000000000a', 'Dispatcher', 'submitted', '20000000-0000-0000-0000-000000000002', 1);  -- Fiona's request
-- Omar (no jobs.approve) cannot send it back; Fiona cannot send back her own; Alex can, with a reason.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  begin
    update public.hiring_requests set status = 'changes_requested', change_reason = 'x' where id = '60000000-0000-0000-0000-000000000033';
    if found then raise exception 'FAIL: Omar sent a request back without jobs.approve'; end if;
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
do $$
begin
  begin
    update public.hiring_requests set status = 'changes_requested', change_reason = 'x' where id = '60000000-0000-0000-0000-000000000033';
    if found then raise exception 'FAIL: Fiona sent her own request back'; end if;
  exception when insufficient_privilege then null;
  end;
  -- Fiona cannot edit her submitted request either.
  begin
    update public.hiring_requests set title = 'Senior Dispatcher' where id = '60000000-0000-0000-0000-000000000033';
    if found then raise exception 'FAIL: edited a submitted request'; end if;
  exception when raise_exception then
    if sqlerrm not like '%cannot be edited%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex, jobs.approve in A
set role authenticated;
do $$
begin
  begin
    update public.hiring_requests set status = 'changes_requested', change_reason = '  ' where id = '60000000-0000-0000-0000-000000000033';
    raise exception 'FAIL: sent back without a reason';
  exception when raise_exception then
    if sqlerrm not like '%what needs to change%' then raise; end if;
  end;
  update public.hiring_requests set status = 'changes_requested', change_reason = 'Add a budget range' where id = '60000000-0000-0000-0000-000000000033';
  assert (select decided_by from public.hiring_requests where id = '60000000-0000-0000-0000-000000000033') = '20000000-0000-0000-0000-000000000001', 'who sent it back is recorded';
  -- Alex is not the requester: he may not resubmit it.
  begin
    update public.hiring_requests set status = 'submitted' where id = '60000000-0000-0000-0000-000000000033';
    raise exception 'FAIL: an approver resubmitted someone else''s request';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona revises and resubmits
set role authenticated;
do $$
begin
  update public.hiring_requests set title = 'Senior Dispatcher', headcount = 2, status = 'submitted' where id = '60000000-0000-0000-0000-000000000033';
  assert (select status || '/' || title || '/' || headcount::text || '/' || coalesce(decided_by::text, 'none') from public.hiring_requests where id = '60000000-0000-0000-0000-000000000033')
    = 'submitted/Senior Dispatcher/2/none', 'revised, back in the queue, decision cleared';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex approves the revision
set role authenticated;
update public.hiring_requests set status = 'approved' where id = '60000000-0000-0000-0000-000000000033';
reset role;
set app.test_uid = '';
do $$
declare v_kinds text[];
begin
  select array_agg(kind order by at) into v_kinds from public.hiring_request_history where request_id = '60000000-0000-0000-0000-000000000033';
  assert v_kinds = array['submitted', 'changes_requested', 'resubmitted', 'approved'], 'history in order: ' || array_to_string(v_kinds, ',');
  assert (select reason from public.hiring_request_history where request_id = '60000000-0000-0000-0000-000000000033' and kind = 'changes_requested') = 'Add a budget range', 'the reason travels with the step';
  assert (select snapshot->>'title' from public.hiring_request_history where request_id = '60000000-0000-0000-0000-000000000033' and kind = 'resubmitted') = 'Senior Dispatcher', 'the revision is snapshotted';
  assert (select actor_id from public.hiring_request_history where request_id = '60000000-0000-0000-0000-000000000033' and kind = 'resubmitted') = '20000000-0000-0000-0000-000000000002', 'who resubmitted';
end $$;

-- ================================================================ 0028
-- Field Notebook import: dry run writes nothing, commit links an existing
-- person by email, creates the rest, keeps legacy ids, reconciles and
-- verifies balances, skips per-faith holidays, grants approvers, and
-- refuses non-admins and mismatched balances.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  begin
    perform public.import_field_notebook('{"companies":[],"people":[]}'::jsonb, false);
    raise exception 'FAIL: non-admin ran the import';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
declare
  payload jsonb := $j${
    "year": 2026,
    "companies": [{"fn_name": "Company A", "short_code": "A"}, {"fn_name": "Old B", "short_code": "B", "rename_to": "Company Bee", "new_short_code": "BEE"}],
    "people": [
      {"fn_id": 1, "name": "Omar Employee", "email": "OMAR@a.test", "company": "Company A", "country": "North Macedonia", "department": "Finance", "position": "Engineer", "is_active": true, "allowance": 22, "remaining": 15},
      {"fn_id": 2, "name": "Nina New", "email": "nina@b.test", "phone": "+389 70 000 000", "company": "Old B", "country": "Serbia", "department": "Sales", "position": "Sales Lead", "is_active": true, "allowance": 20, "remaining": 18, "first_request": "2025-12-29"},
      {"fn_id": 3, "name": "Gone Gary", "email": "gary@b.test", "company": "Old B", "country": "North Macedonia", "is_active": false, "allowance": 20, "remaining": 20, "updated_at": "2026-03-01T10:00:00Z"},
      {"fn_id": 4, "name": "No Mail", "email": "", "company": "Old B", "country": "Malta", "is_active": true, "allowance": 1, "remaining": 1}
    ],
    "requests": [
      {"fn_id": 101, "person_fn_id": 1, "type": "Annual leave", "start": "2026-02-02", "end": "2026-02-06", "working_days": 5, "carry_over_used": 0, "note": "Ski", "status": "approved", "submitted_by_email": "omar@a.test", "decided_by_email": "ada@holding.test", "decided_at": "2026-01-20T09:00:00Z", "created_at": "2026-01-19T09:00:00Z"},
      {"fn_id": 102, "person_fn_id": 1, "type": "Annual leave", "start": "2026-03-02", "end": "2026-03-03", "working_days": 2, "carry_over_used": 0, "status": "rejected", "created_at": "2026-02-19T09:00:00Z"},
      {"fn_id": 103, "person_fn_id": 2, "type": "Justified day", "start": "2026-04-01", "end": "2026-04-01", "working_days": 1, "carry_over_used": 0, "status": "approved", "created_at": "2026-03-19T09:00:00Z"},
      {"fn_id": 104, "person_fn_id": 2, "type": "Annual leave", "start": "2025-12-29", "end": "2025-12-30", "working_days": 2, "carry_over_used": 0, "status": "approved", "created_at": "2025-12-01T09:00:00Z"},
      {"fn_id": 105, "person_fn_id": 2, "type": "Mystery", "start": "2026-05-01", "end": "2026-05-01", "working_days": 1, "status": "approved"}
    ],
    "adjustments": [
      {"person_fn_id": 1, "days": -1, "kind": "manual_adjustment", "reason": "Took a half day twice", "created_by_email": "ada@holding.test", "created_at": "2026-05-01T10:00:00Z"},
      {"person_fn_id": 1, "days": -5, "kind": "leave_approved", "reason": "mirrors 101"}
    ],
    "holidays": [
      {"country": "North Macedonia", "date": "2026-10-11", "name": "Day of the Uprising", "universal": true},
      {"country": "North Macedonia", "date": "2026-12-25", "name": "Christmas (Catholic)", "universal": false},
      {"country": "Serbia", "date": "2026-02-15", "name": "Statehood Day", "universal": true}
    ],
    "approvers": [{"email": "omar@a.test", "short_codes": ["A", "BEE"]}, {"email": "nobody@x.test", "short_codes": ["A"]}]
  }$j$;
  report jsonb;
  b jsonb;
  nina uuid;
  n int;
begin
  -- Dry run: verdicts, nothing written.
  report := public.import_field_notebook(payload, false);
  assert (report->>'committed') = 'false', 'dry run';
  assert (report->'counts'->>'people_created')::int = 2 and (report->'counts'->>'people_linked')::int = 1, 'two created, Omar linked: ' || (report->'counts')::text;
  assert (report->'counts'->>'refused')::int = 3, 'no-mail person, mystery type, unknown approver refused: ' || (report->'counts')::text;
  assert (report->'counts'->>'requests')::int = 4, 'four requests ready';
  assert (report->'counts'->>'holidays')::int = 2 and (report->'counts'->>'holidays_skipped')::int = 1, 'per-faith holiday skipped';
  assert (select x->>'reconciled_by' from jsonb_array_elements(report->'balances') x where x->>'name' = 'Omar Employee') = '-1', 'dry run predicts the reconciliation: ' || (report->'balances')::text;
  assert (select count(*) from jsonb_array_elements(report->'assumptions') x where x ? 'country_code') = 1, 'one country assumption per company (A already has MK): ' || (report->'assumptions')::text;
  assert jsonb_array_length(report->'grants') = 2, 'BEE resolves through the rename during the dry run: ' || (report->'grants')::text;
  assert not exists (select 1 from public.people where lower(work_email) = 'nina@b.test'), 'dry run wrote nothing';
  assert (select name from public.companies where id = '10000000-0000-0000-0000-00000000000b') = 'Company B', 'dry run did not rename';

  -- Commit with refusals is refused.
  begin
    perform public.import_field_notebook(payload, true);
    raise exception 'FAIL: committed with refused rows';
  exception when others then
    if sqlerrm not like '%refused%' then raise; end if;
  end;
  assert not exists (select 1 from public.people where lower(work_email) = 'nina@b.test'), 'refused commit rolled back';

  -- Clean payload commits.
  payload := jsonb_set(payload, '{people}', (payload->'people') - 3);
  payload := jsonb_set(payload, '{requests}', (payload->'requests') - 4);
  payload := jsonb_set(payload, '{approvers}', jsonb_build_array(payload->'approvers'->0));
  report := public.import_field_notebook(payload, true);
  assert (report->>'committed') = 'true', 'committed';
  select id into nina from public.people where work_email = 'nina@b.test';
  assert nina is not null and (select phone from public.people where id = nina) = '+389 70 000 000', 'Nina created with phone';
  assert (select custom->'field_notebook'->>'id' from public.people where id = nina) = '2', 'source id kept';
  assert (select count(*) from public.people where lower(work_email) = 'omar@a.test') = 1, 'Omar linked, not duplicated';
  assert (select name || '/' || short_code from public.companies where id = '10000000-0000-0000-0000-00000000000b') = 'Company Bee/BEE', 'renamed on commit';
  assert (select country_code from public.companies where id = '10000000-0000-0000-0000-00000000000b') = 'RS', 'majority country of active people (Nina in Serbia; Gary is former)';
  -- Nina's period: Sales Lead, shared Sales department, started with her earliest request, no location (RS = company country).
  select count(*) into n from public.employment_periods ep join public.departments d on d.id = ep.department_id
    where ep.person_id = nina and ep.job_title = 'Sales Lead' and d.company_id is null and d.name = 'Sales'
      and ep.start_date = '2025-12-29' and ep.status = 'active' and ep.location_id is null;
  assert n = 1, 'Nina''s employment';
  assert (select status || '/' || end_date::text from public.employment_periods ep join public.people p on p.id = ep.person_id where p.work_email = 'gary@b.test') = 'former/2026-03-01', 'Gary former with the last update as end';
  -- Gary is in MK at an RS company: a location was created for him.
  assert (select l.country_code from public.employment_periods ep join public.people p on p.id = ep.person_id join public.locations l on l.id = ep.location_id where p.work_email = 'gary@b.test') = 'MK', 'Gary''s location';
  assert (select country_code from public.companies where id = '10000000-0000-0000-0000-00000000000a') = 'MK', 'Company A country';
  -- Requests with legacy ids, actors resolved.
  assert (select count(*) from public.leave_requests where legacy_id in (101, 102, 103, 104)) = 4, 'four requests';
  assert (select decided_by from public.leave_requests where legacy_id = 101) = '20000000-0000-0000-0000-000000000004', 'decider resolved by email';
  assert (select status from public.leave_requests where legacy_id = 102) = 'rejected', 'status kept';
  -- Balances reconciled to the source and verified.
  b := public.leave_balance('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000a', 2026);
  assert (b->>'entitlement')::numeric = 22 and (b->>'used')::numeric = 5 and (b->>'remaining')::numeric = 15, 'Omar: 22 - 5 - 1 manual - 1 reconciliation = 15: ' || (b)::text;
  assert (select count(*) from public.leave_adjustments a join public.leave_balances lb on lb.id = a.balance_id
          where lb.person_id = '20000000-0000-0000-0000-000000000003' and lb.year = 2026 and a.kind = 'import') = 2, 'manual adjustment + reconciliation, the mirror row ignored';
  b := public.leave_balance(nina, '10000000-0000-0000-0000-00000000000b', 2026);
  assert (b->>'remaining')::numeric = 18 and (b->>'used')::numeric = 0, 'Nina: justified day does not deduct; 2025 request is another year; reconciled -2: ' || (b)::text;
  assert (select count(*) from jsonb_array_elements(report->'balances') x where (x->>'verified')::boolean) = 3, 'every balance verified: ' || (report->'balances')::text;
  -- Holidays and grants.
  assert (select count(*) from public.public_holidays where country_code = 'MK' and date = '2026-10-11') = 1, 'MK holiday';
  assert (select count(*) from public.public_holidays where date = '2026-12-25' and country_code = 'MK') = 0, 'per-faith skipped';
  assert (select count(*) from public.grant_capabilities gc join public.access_grants g on g.id = gc.grant_id
          where g.person_id = '20000000-0000-0000-0000-000000000003' and gc.capability_key = 'leave.approve') = 2, 'Omar approves in A and BEE';
  -- Re-run: legacy ids already there, nothing duplicated.
  report := public.import_field_notebook(payload, true);
  assert (report->'counts'->>'requests_already_there')::int = 4 and (report->'counts'->>'requests')::int = 0, 'idempotent requests';
  assert (select count(*) from public.people where lower(work_email) = 'nina@b.test') = 1, 'Nina not duplicated';
  assert (select count(*) from public.leave_requests where legacy_id in (101, 102, 103, 104)) = 4, 'no duplicate requests';
  -- A linked person employed elsewhere over the same dates is refused, not double-employed.
  report := public.import_field_notebook(jsonb_set(payload, '{people}', jsonb_build_array(
    jsonb_build_object('fn_id', 9, 'name', 'Fiona Finance', 'email', 'fiona@a.test', 'company', 'Old B', 'country', 'Serbia', 'is_active', true, 'allowance', 20, 'remaining', 20))), false);
  assert (report->'rows'->0->'problems'->>0) like 'already employed in another company%', 'overlap refused: ' || (report->'rows')::text;
  -- A second run reconciles nothing further: the ledger already shows the source numbers.
  assert (select count(*) from public.leave_adjustments a join public.leave_balances lb on lb.id = a.balance_id
          where lb.person_id = '20000000-0000-0000-0000-000000000003' and lb.year = 2026 and a.kind = 'import') = 2, 'no second reconciliation';
  assert (select count(*) from jsonb_array_elements(report->'balances') x where (x->>'reconciled_by')::numeric <> 0) = 0, 'nothing to reconcile on a re-run: ' || (report->'balances')::text;
end $$;
reset role;
set app.test_uid = '';

select 'SMOKE TESTS PASSED' as result;
