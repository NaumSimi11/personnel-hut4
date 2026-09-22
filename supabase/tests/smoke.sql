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
          where plan_id = (first->>'plan_id')::uuid) = 11,
    'onboarding plan carries the 11 template tasks (0040 defaults)';
  again := public.confirm_hire('90000000-0000-0000-0000-000000000002',
    'Hired Candidate', 'Coordinator', current_date);
  assert (again->>'already_hired')::boolean = true, 'second confirm is a no-op';
  assert again->>'employment_period_id' = first->>'employment_period_id',
    'retry returns the same employment period';
  -- The address they applied from stays personal on the record (plan 046).
  assert (select count(*) from public.employment_periods ep
          join public.people p on p.id = ep.person_id
          where p.personal_email = 'hired-candidate@example.test') = 1,
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
          where plan_id = (first->>'plan_id')::uuid) = 8,
    'offboarding plan carries the 8 template tasks (0040 defaults)';
  assert (select count(*) from public.plan_tasks
          where plan_id = (first->>'plan_id')::uuid
            and due_date = current_date + 28) = 3,
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
  assert (done->>'open_tasks')::int = 8, 'outstanding tasks are reported, not blocking';
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
  -- Since 0046 the author may approve their own offer; approved_by records that they did.
  perform public.advance_offer('d0000000-0000-0000-0000-000000000002', 'approved', null);
  assert (select status || '|' || approved_by from public.offers where id = 'd0000000-0000-0000-0000-000000000002')
         = 'approved|20000000-0000-0000-0000-000000000002', 'the author''s own approval is recorded on the offer (0046)';
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
  assert (select change_reason from public.hiring_requests where id = '60000000-0000-0000-0000-000000000033') is null, 'the old reason is cleared on resubmit (history keeps it)';
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

-- ================================================================ 0034
-- Notifications: a request tells the approvers (HR inbox when set), a
-- decision tells the person, nothing is doubled, people read only their
-- own and mark them read; hiring and document events likewise.
set app.test_uid = '';
update public.companies set hr_notification_email = 'hr@a.test' where id = '10000000-0000-0000-0000-00000000000a';
update public.people set work_email = 'pia@a.test' where id = '20000000-0000-0000-0000-000000000021';
delete from public.notifications;  -- earlier blocks fired the triggers; start counting here
-- Pia files a request → Alex (leave.approve in A) is told, to the HR inbox.
set app.test_uid = '00000000-0000-0000-0000-000000000021';
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-11-08', '2027-11-09', 'Long weekend');
  perform set_config('app.smoke_req', r->>'request_id', false);
  assert (select count(*) from public.notifications) = 0, 'Pia sees none of the approvers'' notifications';
end $$;
reset role;
set app.test_uid = '';
do $$
declare n record;
begin
  select * into n from public.notifications where kind = 'leave.requested' and person_id = '20000000-0000-0000-0000-000000000001';
  assert n.title = 'Leave request from Pia Planner', 'approver notified: ' || coalesce(n.title, 'none');
  assert n.email_to = 'hr@a.test' and n.email_status = 'pending', 'HR inbox, queued: ' || coalesce(n.email_to, 'none');
  assert n.link = '/leave?tab=requests' and n.body like 'Annual leave · 08 Nov → 09 Nov 2027 · 2 working days — "Long weekend"', 'body: ' || n.body;
  assert (select count(*) from public.notifications where dedupe_key like 'leave.requested:' || current_setting('app.smoke_req') || ':%') = 1, 'one row per event and recipient';
  -- A second approver gets their own row for the same event.
  insert into public.grant_capabilities (grant_id, capability_key) values ('40000000-0000-0000-0000-000000000002', 'leave.approve') on conflict do nothing;  -- Fiona too
  perform app.notify('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', 'leave.requested', 'Leave request from Pia Planner', 'x', '/leave?tab=requests',
    'leave_request', current_setting('app.smoke_req')::uuid, 'leave.requested:' || current_setting('app.smoke_req'), true);
  perform app.notify('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', 'leave.requested', 'Leave request from Pia Planner', 'x', '/leave?tab=requests',
    'leave_request', current_setting('app.smoke_req')::uuid, 'leave.requested:' || current_setting('app.smoke_req'), true);
  assert (select count(*) from public.notifications where dedupe_key like 'leave.requested:' || current_setting('app.smoke_req') || ':%') = 2, 'two recipients, one row each, repeats ignored';
end $$;
-- Alex approves → Pia is told at her own address; Alex reads his own row; RLS keeps Pia's rows from him.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
declare n record;
begin
  perform public.decide_leave(current_setting('app.smoke_req')::uuid, 'approved', 'Enjoy');
  assert (select count(*) from public.notifications where person_id <> '20000000-0000-0000-0000-000000000001') = 0, 'Alex reads only his own';
  assert (select count(*) from public.notifications where read_at is null) = 1, 'one unread';
  assert public.mark_notifications_read() = 1, 'marked read';
  assert (select count(*) from public.notifications where read_at is null) = 0, 'none unread';
end $$;
reset role;
set app.test_uid = '';
do $$
declare n record;
begin
  select * into n from public.notifications where kind = 'leave.decided' and person_id = '20000000-0000-0000-0000-000000000021';
  assert n.title = 'Your leave was approved: 08 Nov → 09 Nov 2027', 'person told: ' || coalesce(n.title, 'none');
  assert n.email_to = 'pia@a.test' and n.body like '%Enjoy · by Alex Director', 'own address, note and decider: ' || n.body;
end $$;
-- A cancellation ask and its decline.
set app.test_uid = '';
update public.leave_requests set start_date = current_date - 1, end_date = current_date, working_days = 2 where id = current_setting('app.smoke_req')::uuid;
set app.test_uid = '00000000-0000-0000-0000-000000000021';
set role authenticated;
select public.request_leave_cancellation(current_setting('app.smoke_req')::uuid, 'Came back early');
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
select public.decline_leave_cancellation(current_setting('app.smoke_req')::uuid, 'Already counted');
reset role;
set app.test_uid = '';
do $$
begin
  assert (select count(*) from public.notifications where kind = 'leave.cancel_asked' and person_id = '20000000-0000-0000-0000-000000000001') = 1, 'approver told of the ask';
  assert (select title from public.notifications where kind = 'leave.cancel_declined' and person_id = '20000000-0000-0000-0000-000000000021') like 'Your leave stands:%', 'person told of the decline';
end $$;
-- Hiring: Fiona submits with Alex as hiring manager → Alex is assigned (awaiting approval) and, being the approver, also gets the request.
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
insert into public.hiring_requests (id, company_id, title, status, requested_by, hiring_manager_id, target_start_date) values
  ('60000000-0000-0000-0000-000000000034', '10000000-0000-0000-0000-00000000000a', 'Fleet Lead', 'submitted', '20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', '2027-03-01');
reset role;
set app.test_uid = '';
do $$
declare n record;
begin
  select * into n from public.notifications where kind = 'hiring.assigned' and person_id = '20000000-0000-0000-0000-000000000001';
  assert n.title = 'You are the hiring manager for Fleet Lead' and n.body like '%target employee start 01 Mar 2027 · awaiting approval%', 'assigned, awaiting: ' || coalesce(n.body, 'none');
  assert n.email_to = 'alex@a.test', 'the manager''s own address (not the HR inbox)';
  assert (select count(*) from public.notifications where kind = 'hiring.submitted' and entity_id = '60000000-0000-0000-0000-000000000034') >= 1, 'approvers told of the request';
end $$;
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
update public.hiring_requests set status = 'approved' where id = '60000000-0000-0000-0000-000000000034';
reset role;
set app.test_uid = '';
do $$
begin
  assert (select title from public.notifications where kind = 'hiring.go' and person_id = '20000000-0000-0000-0000-000000000001') = 'Recruitment can proceed: Fleet Lead', 'go-ahead to the manager';
  assert (select title from public.notifications where kind = 'hiring.decided' and person_id = '20000000-0000-0000-0000-000000000002') = 'Hiring request approved: Fleet Lead', 'requester told';
end $$;
-- Approver with no work email: the in-app row stays, the mail is skipped.
update public.people set work_email = null where id = '20000000-0000-0000-0000-000000000001';
update public.companies set hr_notification_email = null where id = '10000000-0000-0000-0000-00000000000a';
set app.test_uid = '00000000-0000-0000-0000-000000000021';
set role authenticated;
select public.request_leave('20000000-0000-0000-0000-000000000021', 'annual', '2027-11-15', '2027-11-15');
reset role;
set app.test_uid = '';
do $$
begin
  assert (select email_status from public.notifications where kind = 'leave.requested' and person_id = '20000000-0000-0000-0000-000000000001' order by created_at desc limit 1) = 'skipped', 'no address → skipped, row kept';
end $$;
update public.people set work_email = 'alex@a.test' where id = '20000000-0000-0000-0000-000000000001';

-- ============================================================ 0035 / 0036
-- Dashboard: the snapshot shows only what the viewer may already see —
-- the team behind people.view, birthdays behind personal.view (day and
-- month, never the year), payroll behind payroll.summary; kudos follow the
-- directory's rule, and the person thanked always reads their own.
set app.test_uid = '';
insert into public.people (id, full_name, work_email) values
  ('20000000-0000-0000-0000-000000000031','Nia Newcomer','nia@a.test'),
  ('20000000-0000-0000-0000-000000000032','Ivo Anniversary','ivo@a.test');
insert into public.employment_periods (id, person_id, company_id, job_title, status, start_date) values
  ('30000000-0000-0000-0000-000000000031','20000000-0000-0000-0000-000000000031','10000000-0000-0000-0000-00000000000a','Designer','active', current_date - 10),
  ('30000000-0000-0000-0000-000000000032','20000000-0000-0000-0000-000000000032','10000000-0000-0000-0000-00000000000a','Analyst','active', (current_date - interval '2 years' + interval '3 days')::date);
insert into public.person_private_details (person_id, birth_date) values
  ('20000000-0000-0000-0000-000000000032', (current_date + 5 - interval '30 years')::date);

-- Omar (employed in A, no grants): a team he may not read is no team at all.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare s jsonb;
begin
  s := public.dashboard_snapshot(30);
  assert (s->>'headcount')::int = 0, 'no people.view, no team';
  assert s->'colleagues' = '[]'::jsonb and s->'birthdays' = '[]'::jsonb
     and s->'anniversaries' = '[]'::jsonb and s->'newcomers' = '[]'::jsonb, 'and none of its facts';
  assert s->'payroll' = '[]'::jsonb and s->'kudos' = '[]'::jsonb, 'no payroll, no kudos';
  assert s->'biggest_team' = 'null'::jsonb and s->'top_kudos' = 'null'::jsonb, 'nothing to be biggest or top';
  begin
    insert into public.kudos (from_person_id, to_person_id, message)
    values ('20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'Thanks!');
    raise exception 'FAIL: kudos to someone I may not see accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Fiona (Finance in A: people.view + payroll.summary, no personal.view).
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
do $$
declare s jsonb; a jsonb;
begin
  s := public.dashboard_snapshot(30);
  assert (s->>'headcount')::int >= 6, 'the team is everyone employed in A';
  assert exists (select 1 from jsonb_array_elements(s->'colleagues') c where c->>'full_name' = 'Alex Director'), 'Alex is in it';
  assert not exists (select 1 from jsonb_array_elements(s->'colleagues') c where c->>'full_name' = 'Bea HR'), 'Bea (Company B) is not';
  assert s->'birthdays' = '[]'::jsonb, 'no personal.view, no birthdays';
  select c into a from jsonb_array_elements(s->'anniversaries') c where c->>'full_name' = 'Ivo Anniversary';
  assert a is not null and (a->>'years')::int = 2 and (a->>'in_days')::int = 3, 'Ivo''s second anniversary is in three days';
  assert exists (select 1 from jsonb_array_elements(s->'newcomers') c where c->>'full_name' = 'Nia Newcomer'), 'Nia started ten days ago';
  assert not exists (select 1 from jsonb_array_elements(s->'anniversaries') c where c->>'full_name' = 'Nia Newcomer'), 'a newcomer has no anniversary yet';
  assert (s->'payroll'->0->>'company_name') = 'Company A' and (s->'payroll'->0->>'total')::numeric > 0, 'the last approved payroll of A, with its total';
  assert (s->'biggest_team'->>'name') = 'Company A', 'the biggest team I can read';
  -- Thanking someone I may see lands, in my own name only.
  insert into public.kudos (from_person_id, to_person_id, message)
  values ('20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003', 'Thanks for the quick handover!');
  begin
    insert into public.kudos (from_person_id, to_person_id, message)
    values ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'Forged');
    raise exception 'FAIL: kudos in someone else''s name accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.kudos (from_person_id, to_person_id, message)
    values ('20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'Me');
    raise exception 'FAIL: kudos to myself accepted';
  exception when check_violation then null;
  end;
  s := public.dashboard_snapshot(30);
  assert (select count(*) from jsonb_array_elements(s->'kudos') k
          where k->>'to_name' = 'Omar Employee' and k->>'from_name' = 'Fiona Finance' and (k->>'mine')::boolean) = 1,
    'the wall shows it with names, marked mine';
end $$;
reset role;

-- Omar reads what he was given, even with nothing else; removing is the giver's.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare s jsonb;
begin
  s := public.dashboard_snapshot(30);
  assert jsonb_array_length(s->'kudos') = 1 and (s->'kudos'->0->>'from_name') = 'Fiona Finance'
     and not (s->'kudos'->0->>'mine')::boolean, 'the kudos I received, not mine to claim';
  assert (s->>'headcount')::int = 0, 'still no team';
  delete from public.kudos;
  assert (select count(*) from public.kudos) = 1, 'the recipient does not remove it';
end $$;
reset role;

-- Ada (platform admin) may read private details, so she gets the birthday — day and month only.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
declare b jsonb;
begin
  select c into b from jsonb_array_elements(public.dashboard_snapshot(30)->'birthdays') c where c->>'full_name' = 'Ivo Anniversary';
  assert b is not null and (b->>'in_days')::int = 5, 'Ivo''s birthday is in five days';
  assert b->>'on_day' !~ '\d{4}' and not (b ? 'birth_date'), 'day and month only, never the year';
end $$;
reset role;

-- Bea (Company B) sees neither A's team nor kudos between its people.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare s jsonb;
begin
  assert (select count(*) from public.kudos) = 0, 'kudos between people I may not see stay hidden';
  s := public.dashboard_snapshot(30);
  assert not exists (select 1 from jsonb_array_elements(s->'colleagues') c where c->>'full_name' = 'Alex Director'), 'A''s people are not her team';
end $$;
reset role;

-- The giver removes it.
set app.test_uid = '00000000-0000-0000-0000-000000000002';
set role authenticated;
delete from public.kudos;
reset role;
set app.test_uid = '';
do $$ begin assert (select count(*) from public.kudos) = 0, 'the giver removed it'; end $$;

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


-- ================================================================ 0037
-- Correcting an employment: only with employment.edit, never onto dates
-- another employment covers, never past the end; the period keeps its id and
-- the old picture is recorded. Its own person and periods, so the section does
-- not depend on what earlier sections did to the shared fixtures.
insert into public.people (id, full_name, work_email)
values ('20000000-0000-0000-0000-0000000000c1', 'Cora Correction', 'cora@a.test');
insert into public.employment_periods (id, person_id, company_id, job_title, employment_type_key, status, start_date, end_date)
values
  ('30000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c1',
   '10000000-0000-0000-0000-00000000000a', 'Analyst', 'full_time', 'former', '2023-01-01', '2023-12-31'),
  ('30000000-0000-0000-0000-0000000000c2', '20000000-0000-0000-0000-0000000000c1',
   '10000000-0000-0000-0000-00000000000a', 'Accountant', null, 'active', '2026-01-01', null);

set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar: no employment.edit
set role authenticated;
do $$
begin
  begin
    perform public.correct_employment('30000000-0000-0000-0000-0000000000c2', '2024-03-01');
    raise exception 'FAIL: corrected an employment without employment.edit';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex: employment.edit in A
set role authenticated;
do $$
declare
  v_id uuid := '30000000-0000-0000-0000-0000000000c2';
  r jsonb;
  c record;
begin
  -- Refused: a start date inside the closed period.
  begin
    perform public.correct_employment(v_id, '2023-06-01');
    raise exception 'FAIL: corrected onto dates another employment covers';
  exception when exclusion_violation then null;
  end;
  -- Refused: an unknown employment type.
  begin
    perform public.correct_employment(v_id, '2024-03-01', null, 'freelance');
    raise exception 'FAIL: accepted an unknown employment type';
  exception when invalid_parameter_value then
    if sqlerrm not like '%Unknown employment type%' then raise; end if;
  end;
  -- Corrected: earlier start, new title; the type was never set and stays unset.
  r := public.correct_employment(v_id, '2024-03-01', 'Finance Lead', null, 'Contract says March 2024');
  assert (r->>'start_date') = '2024-03-01' and (r->>'job_title') = 'Finance Lead', 'corrected: ' || r::text;
  assert (r->>'status') = 'active', 'a past start date on a running period stays active: ' || r::text;
  assert (select start_date from public.employment_periods where id = v_id) = '2024-03-01', 'the period itself moved';
  assert (select employment_type_key from public.employment_periods where id = v_id) is null,
    'null leaves the type alone — including when the period never had one';
  -- The old picture is kept, with who and why.
  select * into c from public.employment_corrections where period_id = v_id order by corrected_at desc limit 1;
  assert c.old_start_date = '2026-01-01' and c.new_start_date = '2024-03-01', 'old and new start recorded';
  assert c.old_job_title = 'Accountant' and c.new_job_title = 'Finance Lead', 'old and new title recorded';
  assert c.reason = 'Contract says March 2024', 'the reason is kept';
  assert c.corrected_by = '20000000-0000-0000-0000-000000000001', 'the corrector is recorded';
  -- A start date in the future puts a running employment back to pre_start.
  r := public.correct_employment(v_id, (current_date + 30)::date);
  assert (r->>'status') = 'pre_start', 'a future start date is pre_start: ' || r::text;
  r := public.correct_employment(v_id, '2024-03-01');
  assert (r->>'status') = 'active', 'and a past one is active again';
  -- A closed period is corrected too, but a correction never revives it.
  r := public.correct_employment('30000000-0000-0000-0000-0000000000c1', '2022-06-01');
  assert (r->>'status') = 'former', 'correcting a former period leaves it former: ' || r::text;
  -- Refused: a start date after the end date.
  begin
    perform public.correct_employment('30000000-0000-0000-0000-0000000000c1', '2024-06-01');
    raise exception 'FAIL: started after the end date';
  exception when invalid_parameter_value then
    if sqlerrm not like '%cannot be after the end date%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '';
-- The audit keeps the correction but never its reason.
do $$
begin
  assert (select count(*) from public.activity_log where entity_type = 'employment_corrections') >= 1,
    'the correction is audited';
  assert (select count(*) from public.activity_log where entity_type = 'employment_corrections' and (after ? 'reason')) = 0,
    'the audit never carries the reason';
end $$;
delete from public.employment_periods where person_id = '20000000-0000-0000-0000-0000000000c1';
delete from public.people where id = '20000000-0000-0000-0000-0000000000c1';

-- ================================================================ 0038
-- The employee record in one call (create_employee), structure open to HR,
-- the private row audited by field name only, corrections of department /
-- location / manager, and the import through the same call.
insert into public.departments (id, company_id, name) values
  ('d0000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Finance A');

-- Structure: Bea (Company HR in B) adds a department in B, is refused in A
-- and for the holding; Omar (leave.approve only) is refused.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
insert into public.departments (id, company_id, name) values
  ('d0000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Operations B');
do $$
begin
  begin
    insert into public.departments (company_id, name) values ('10000000-0000-0000-0000-00000000000a', 'Not mine');
    raise exception 'FAIL: HR of B added a department in A';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.locations (company_id, name) values (null, 'Holding wide');
    raise exception 'FAIL: HR added a holding-wide location';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  begin
    insert into public.departments (company_id, name) values ('10000000-0000-0000-0000-00000000000a', 'Omar dept');
    raise exception 'FAIL: a person without grants added a department';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- create_employee by Bea: everything but pay (she holds no salary.propose).
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare
  r jsonb;
  pd record;
begin
  r := public.create_employee(jsonb_build_object(
    'full_name', 'Nora Newhire', 'preferred_name', 'Nori',
    'work_email', 'nora@b.test', 'personal_email', 'nora.home@example.test', 'phone', '+389 70 111 222',
    'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Operations Analyst',
    'department_id', 'd0000000-0000-0000-0000-0000000000b1', 'employment_type_key', 'full_time',
    'manager_id', '20000000-0000-0000-0000-000000000005', 'start_date', (current_date + 7),
    'private', jsonb_build_object(
      'birth_date', '1990-05-17', 'address_line', 'Partizanska 1, Skopje',
      'national_id', '1705990450001', 'bank_name', 'Komercijalna', 'bank_account_number', '300000000012345',
      'emergency_name', 'Petar Newhire', 'emergency_relationship', 'brother', 'emergency_phone', '+389 70 333 444',
      'notes', 'Vegetarian')));
  assert (r->>'person_id') is not null and (r->>'employment_period_id') is not null, 'person and period created: ' || r::text;
  assert (r->>'plan_id') is not null, 'the onboarding checklist started: ' || r::text;
  assert (select count(*) from public.plan_tasks where plan_id = (r->>'plan_id')::uuid) = 11, 'the checklist carries the template tasks';
  assert (select status from public.employment_periods where id = (r->>'employment_period_id')::uuid) = 'pre_start', 'a future start is pre_start';
  assert (select department_id from public.employment_periods where id = (r->>'employment_period_id')::uuid) = 'd0000000-0000-0000-0000-0000000000b1', 'department set';
  assert (select manager_id from public.employment_periods where id = (r->>'employment_period_id')::uuid) = '20000000-0000-0000-0000-000000000005', 'manager set';
  assert (select personal_email::text from public.people where id = (r->>'person_id')::uuid) = 'nora.home@example.test', 'personal email on the person';
  select * into pd from public.person_private_details where person_id = (r->>'person_id')::uuid;
  assert pd.national_id = '1705990450001' and pd.national_id_hint = '0001', 'national id kept, hint derived';
  assert pd.bank_account->>'account_number' = '300000000012345' and pd.bank_account->>'bank' = 'Komercijalna', 'bank account kept';
  assert pd.emergency_contacts->0->>'relationship' = 'brother' and pd.emergency_contacts->0->>'name' = 'Petar Newhire', 'the emergency contact carries a relationship';
  assert pd.birth_date = '1990-05-17' and pd.address->>'line' = 'Partizanska 1, Skopje' and pd.notes = 'Vegetarian', 'the rest of the private row';

  -- No salary.propose: the pay part is refused before anything is written.
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Paid Person', 'company_id', '10000000-0000-0000-0000-00000000000b',
      'job_title', 'Clerk', 'start_date', current_date,
      'pay', jsonb_build_object('amount', 1000, 'currency', 'EUR', 'pay_basis_key', 'monthly')));
    raise exception 'FAIL: pay proposed without salary.propose';
  exception when insufficient_privilege then null;
  end;
  assert not exists (select 1 from public.people where full_name = 'Paid Person'), 'a refused call writes nothing';

  -- The same work email twice is refused, never merged.
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Nora Again', 'work_email', 'NORA@b.test',
      'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date));
    raise exception 'FAIL: duplicate work email accepted';
  exception when unique_violation then null;
  end;

  -- A department of another company is refused by the shared validator.
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Wrong Dept', 'company_id', '10000000-0000-0000-0000-00000000000b',
      'job_title', 'Clerk', 'start_date', current_date,
      'department_id', 'd0000000-0000-0000-0000-0000000000a1'));
    raise exception 'FAIL: a department of another company accepted';
  exception when invalid_parameter_value then
    if sqlerrm not like '%another company%' then raise; end if;
  end;

  -- Not asked for: no checklist; a past start is active.
  r := public.create_employee(jsonb_build_object(
    'full_name', 'Old Timer', 'company_id', '10000000-0000-0000-0000-00000000000b',
    'job_title', 'Clerk', 'start_date', '2020-01-01', 'start_onboarding', false));
  assert (r->>'plan_id') is null, 'no checklist when not asked';
  assert (select status from public.employment_periods where id = (r->>'employment_period_id')::uuid) = 'active', 'a past start is active';
end $$;
reset role;

-- Omar with employment.edit only in A: the private part is refused, a plain
-- add goes through and starts the checklist, B stays closed to him.
-- Omar already holds a grant in A (leave.approve, from the 0028 block): add to
-- it, and take exactly these two away again at the end.
create temp table omar_added as
  select g.id as grant_id, v.cap as capability_key
  from public.access_grants g, (values ('people.view'), ('employment.edit')) v(cap)
  where g.person_id = '20000000-0000-0000-0000-000000000003'
    and g.company_id = '10000000-0000-0000-0000-00000000000a'
    and not exists (select 1 from public.grant_capabilities gc where gc.grant_id = g.id and gc.capability_key = v.cap);
insert into public.grant_capabilities (grant_id, capability_key) select grant_id, capability_key from omar_added;
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare r jsonb;
begin
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Secret Person', 'company_id', '10000000-0000-0000-0000-00000000000a',
      'job_title', 'Clerk', 'start_date', current_date,
      'private', jsonb_build_object('national_id', '9999999999999')));
    raise exception 'FAIL: private details written without personal.view';
  exception when insufficient_privilege then null;
  end;
  assert not exists (select 1 from public.people where full_name = 'Secret Person'), 'refused before the person was written';
  -- Blank private values are not a private part.
  r := public.create_employee(jsonb_build_object(
    'full_name', 'Plain Add', 'company_id', '10000000-0000-0000-0000-00000000000a',
    'job_title', 'Clerk', 'start_date', current_date,
    'private', jsonb_build_object('national_id', '  ', 'notes', '')));
  assert (r->>'plan_id') is not null, 'HR without personal.view still starts the checklist';
  assert not exists (select 1 from public.person_private_details where person_id = (r->>'person_id')::uuid), 'no private row from blanks';
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Elsewhere', 'company_id', '10000000-0000-0000-0000-00000000000b',
      'job_title', 'Clerk', 'start_date', current_date));
    raise exception 'FAIL: added an employee without employment.edit';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Ada (admin) with pay: a proposal from the start date, decided by someone else later.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
declare
  r jsonb;
  c record;
begin
  r := public.create_employee(jsonb_build_object(
    'full_name', 'Paid Person', 'work_email', 'paid@b.test',
    'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date,
    'pay', jsonb_build_object('amount', '1500.50', 'currency', 'eur', 'pay_basis_key', 'monthly', 'note', 'Offer letter')));
  assert (r->>'compensation_record_id') is not null, 'a pay proposal was recorded: ' || r::text;
  select * into c from public.compensation_records where id = (r->>'compensation_record_id')::uuid;
  assert c.status = 'proposed' and c.amount = 1500.50 and c.currency = 'EUR' and c.effective_date = current_date
     and c.proposed_by = '20000000-0000-0000-0000-000000000004', 'proposed, not approved, from the start date';
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Bad Pay', 'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date,
      'pay', jsonb_build_object('amount', 'lots', 'currency', 'EUR', 'pay_basis_key', 'monthly')));
    raise exception 'FAIL: a non-numeric amount accepted';
  exception when invalid_parameter_value then null;
  end;
end $$;
reset role;

-- The private row is audited by field name only.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
update public.person_private_details
   set bank_account = '{"bank": "NLB", "account_number": "210000000099"}'::jsonb
 where person_id = (select id from public.people where work_email = 'nora@b.test');
reset role;
set app.test_uid = '';
do $$
begin
  assert exists (select 1 from public.activity_log
                 where entity_type = 'person_private_details' and action = 'INSERT'
                   and after->'fields' ? 'bank_account' and after->'fields' ? 'national_id'),
    'the insert is audited with its field names';
  assert (select after->'fields' from public.activity_log
          where entity_type = 'person_private_details' and action = 'UPDATE'
          order by at desc limit 1) = '["bank_account"]'::jsonb,
    'the update names only the column that changed';
  assert (select actor_person_id from public.activity_log
          where entity_type = 'person_private_details' and action = 'UPDATE'
          order by at desc limit 1) = '20000000-0000-0000-0000-000000000005',
    'and who changed it';
  assert not exists (select 1 from public.activity_log
                     where before::text like '%1705990450001%' or after::text like '%1705990450001%'
                        or before::text like '%300000000012345%' or after::text like '%210000000099%'
                        or before::text like '%Partizanska%' or after::text like '%Partizanska%'),
    'the audit never carries a value from the private row';
end $$;

-- correct_employment with p_fields: department / location / manager.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare
  v_id uuid;
  r jsonb;
  c record;
begin
  select ep.id into v_id from public.employment_periods ep
    join public.people p on p.id = ep.person_id where p.work_email = 'nora@b.test';
  begin
    perform public.correct_employment(v_id, current_date + 7, null, null, 'wrong',
      jsonb_build_object('department_id', 'd0000000-0000-0000-0000-0000000000a1'));
    raise exception 'FAIL: corrected onto another company''s department';
  exception when raise_exception then
    if sqlerrm not like '%another company%' then raise; end if;
  end;
  begin
    perform public.correct_employment(v_id, current_date + 7, null, null, null, '{"status": "former"}'::jsonb);
    raise exception 'FAIL: an unknown field accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.correct_employment(v_id, current_date + 7, null, null, null,
      jsonb_build_object('manager_id', (select person_id from public.employment_periods where id = v_id)));
    raise exception 'FAIL: own manager accepted';
  exception when raise_exception then
    if sqlerrm not like '%own manager%' then raise; end if;
  end;
  -- Clear the department; the manager (absent key) stays; old and new kept.
  r := public.correct_employment(v_id, current_date + 7, null, null, 'No department yet', '{"department_id": null}'::jsonb);
  assert (r->>'department_id') is null and (r->>'manager_id') = '20000000-0000-0000-0000-000000000005',
    'department cleared, manager kept: ' || r::text;
  select * into c from public.employment_corrections where period_id = v_id order by corrected_at desc limit 1;
  assert c.old_department_id = 'd0000000-0000-0000-0000-0000000000b1' and c.new_department_id is null
     and c.old_manager_id = c.new_manager_id and c.reason = 'No department yet', 'old and new department kept';
  r := public.correct_employment(v_id, current_date + 7, 'Senior Operations Analyst', null, null,
    jsonb_build_object('department_id', 'd0000000-0000-0000-0000-0000000000b1', 'manager_id', null));
  assert (r->>'department_id') = 'd0000000-0000-0000-0000-0000000000b1' and (r->>'manager_id') is null
     and (r->>'job_title') = 'Senior Operations Analyst', 'set the department, cleared the manager: ' || r::text;
  -- Without p_fields the call is 0037's: everything else stays.
  r := public.correct_employment(v_id, current_date + 8);
  assert (r->>'department_id') = 'd0000000-0000-0000-0000-0000000000b1' and (r->>'start_date') = (current_date + 8)::text,
    'absent fields keep everything: ' || r::text;
end $$;
reset role;

-- Import: a private column without personal.view is refused before a row is
-- judged; Bea imports private details, a future starter gets the checklist,
-- a backfilled one does not; Ada imports a salary as a proposal.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  begin
    perform public.import_people('10000000-0000-0000-0000-00000000000a', jsonb_build_array(jsonb_build_object(
      'full_name', 'Imp One', 'work_email', 'imp1@a.test', 'job_title', 'Clerk', 'start_date', current_date::text,
      'bank_account_number', '123456789')), false);
    raise exception 'FAIL: previewed a file with bank details without personal.view';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.import_people('10000000-0000-0000-0000-00000000000b', jsonb_build_array(
    jsonb_build_object('full_name', 'Imp Future', 'work_email', 'imp-future@b.test', 'job_title', 'Clerk',
      'start_date', (current_date + 10)::text, 'national_id', '0101990450002',
      'emergency_contact_name', 'Ana', 'emergency_contact_relationship', 'wife', 'emergency_contact_phone', '070',
      'personal_email', 'future.home@example.test'),
    jsonb_build_object('full_name', 'Imp Past', 'work_email', 'imp-past@b.test', 'job_title', 'Clerk',
      'start_date', '2021-03-01', 'birth_date', '1985-02-03', 'manager_email', 'imp-future@b.test')), true);
  assert (r->>'committed')::boolean, 'imported: ' || r::text;
  assert exists (select 1 from public.plans pl join public.people p on p.id = pl.person_id
                 where p.work_email = 'imp-future@b.test' and pl.kind = 'onboarding'), 'a future starter gets the checklist';
  assert not exists (select 1 from public.plans pl join public.people p on p.id = pl.person_id
                     where p.work_email = 'imp-past@b.test'), 'a backfilled employee gets none';
  assert (select pd.national_id_hint from public.person_private_details pd join public.people p on p.id = pd.person_id
          where p.work_email = 'imp-future@b.test') = '0002', 'private row imported';
  assert (select pd.emergency_contacts->0->>'relationship' from public.person_private_details pd join public.people p on p.id = pd.person_id
          where p.work_email = 'imp-future@b.test') = 'wife', 'relationship imported';
  assert (select p.personal_email::text from public.people p where p.work_email = 'imp-future@b.test') = 'future.home@example.test', 'personal email imported';
  assert (select pd.birth_date from public.person_private_details pd join public.people p on p.id = pd.person_id
          where p.work_email = 'imp-past@b.test') = '1985-02-03', 'birth date imported';
  assert (select ep.manager_id from public.employment_periods ep join public.people p on p.id = ep.person_id
          where p.work_email = 'imp-past@b.test') = (select id from public.people where work_email = 'imp-future@b.test'),
    'manager linked from the file';
  -- A bad birth date is a row problem, said in the preview.
  r := public.import_people('10000000-0000-0000-0000-00000000000b', jsonb_build_array(jsonb_build_object(
    'full_name', 'Imp Bad', 'work_email', 'imp-bad@b.test', 'job_title', 'Clerk', 'start_date', current_date::text,
    'birth_date', '03.02.85x')), false);
  assert (r->>'refused')::int = 1 and (r->'rows'->0->'problems')::text like '%birth date is not a date%', 'a bad birth date is a row problem: ' || r::text;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.import_people('10000000-0000-0000-0000-00000000000b', jsonb_build_array(jsonb_build_object(
    'full_name', 'Imp Bad Pay', 'work_email', 'imp-badpay@b.test', 'job_title', 'Clerk', 'start_date', current_date::text,
    'salary_amount', 'lots', 'salary_currency', 'EUR', 'salary_basis', 'monthly')), false);
  assert (r->>'refused')::int = 1 and (r->'rows'->0->'problems')::text like '%not a number%', 'a bad salary is a row problem: ' || r::text;
  r := public.import_people('10000000-0000-0000-0000-00000000000b', jsonb_build_array(jsonb_build_object(
    'full_name', 'Imp Paid', 'work_email', 'imp-paid@b.test', 'job_title', 'Clerk', 'start_date', current_date::text,
    'salary_amount', '900', 'salary_currency', 'eur', 'salary_basis', 'monthly')), true);
  assert exists (select 1 from public.compensation_records cr
                 join public.employment_periods ep on ep.id = cr.employment_period_id
                 join public.people p on p.id = ep.person_id
                 where p.work_email = 'imp-paid@b.test' and cr.status = 'proposed' and cr.amount = 900 and cr.currency = 'EUR'),
    'salary imported as a proposal';
end $$;
reset role;
set app.test_uid = '';
-- Omar is back to what he held before this block.
delete from public.grant_capabilities gc using omar_added a
  where gc.grant_id = a.grant_id and gc.capability_key = a.capability_key;
drop table omar_added;

-- ================================================================ 0039
-- Review of 0038: one person per work email is a constraint; the hint
-- follows a cleared national ID; a hire attaches only to a person with no
-- open employment; a hire always gets its checklist; the preview and the
-- write share one rule set.
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea, Company HR in B
set role authenticated;
do $$
declare r jsonb; v_person uuid;
begin
  -- Same work email, different case: the constraint refuses, in words.
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Nora Twice', 'work_email', 'Nora@B.test',
      'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date));
    raise exception 'FAIL: duplicate work email accepted by the constraint';
  exception when unique_violation then
    if sqlerrm not like '%already exists%' then raise; end if;
  end;
  -- Edit details cannot make two people share a work email either.
  select id into v_person from public.people where work_email = 'paid@b.test';
  begin
    update public.people set work_email = 'nora@b.test' where id = v_person;
    raise exception 'FAIL: an update made two people share a work email';
  exception when unique_violation then null;
  end;
  -- Clearing the national ID clears the hint.
  update public.person_private_details set national_id = null
    where person_id = (select id from public.people where work_email = 'nora@b.test');
  assert (select national_id_hint from public.person_private_details
          where person_id = (select id from public.people where work_email = 'nora@b.test')) is null,
    'the hint follows a cleared national ID';
  -- The shared checker speaks for both routes: the same sentence from the
  -- preview and from the call.
  r := public.import_people('10000000-0000-0000-0000-00000000000b', jsonb_build_array(jsonb_build_object(
    'full_name', 'Imp Rules', 'work_email', 'imp-rules@b.test', 'job_title', 'Clerk', 'start_date', current_date::text,
    'national_id', '12')), false);
  assert (r->'rows'->0->'problems')::text like '%between 4 and 32%', 'the preview names the rule: ' || r::text;
  begin
    perform public.create_employee(jsonb_build_object(
      'full_name', 'Short Id', 'company_id', '10000000-0000-0000-0000-00000000000b',
      'job_title', 'Clerk', 'start_date', current_date, 'private', jsonb_build_object('national_id', '12')));
    raise exception 'FAIL: a short national ID accepted';
  exception when invalid_parameter_value then
    if sqlerrm not like '%between 4 and 32%' then raise; end if;
  end;
end $$;
reset role;

-- A hire from an application: the candidate's address stays personal, the
-- checklist always starts (a late confirmation included), and a colleague
-- who shares the address is never merged into.
insert into public.people (id, full_name, work_email, personal_email) values
  ('20000000-0000-0000-0000-0000000000d1', 'Petar Spouse', 'petar@b.test', 'family@example.test');
insert into public.employment_periods (person_id, company_id, job_title, status, start_date) values
  ('20000000-0000-0000-0000-0000000000d1', '10000000-0000-0000-0000-00000000000b', 'Clerk', 'active', '2024-01-01');
insert into public.jobs (id, company_id, title, status) values
  ('70000000-0000-0000-0000-0000000000d1', '10000000-0000-0000-0000-00000000000b', 'Family Role', 'open');
insert into public.candidates (id, full_name, email) values
  ('80000000-0000-0000-0000-0000000000d1', 'Ana Spouse', 'family@example.test');
insert into public.applications (id, job_id, company_id, candidate_id, stage_key) values
  ('90000000-0000-0000-0000-0000000000d1', '70000000-0000-0000-0000-0000000000d1',
   '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-0000000000d1', 'offer');
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.create_employee(jsonb_build_object(
    'application_id', '90000000-0000-0000-0000-0000000000d1',
    'full_name', 'Ana Spouse', 'job_title', 'Family Role', 'start_date', (current_date - 60),
    'start_onboarding', false));
  assert (r->>'person_id') <> '20000000-0000-0000-0000-0000000000d1', 'a new hire is not merged into a colleague sharing the address';
  assert (select personal_email::text from public.people where id = (r->>'person_id')::uuid) = 'family@example.test'
     and (select work_email from public.people where id = (r->>'person_id')::uuid) is null,
    'the address they applied from stays personal';
  assert (r->>'plan_id') is not null, 'a hire always gets its checklist, even confirmed late: ' || r::text;
  assert (select stage_key from public.applications where id = '90000000-0000-0000-0000-0000000000d1') = 'hired', 'application hired';
  -- A hire that types a colleague's work email is refused like a plain add.
  begin
    perform public.create_employee(jsonb_build_object(
      'application_id', '90000000-0000-0000-0000-0000000000d1', 'work_email', 'petar@b.test',
      'full_name', 'X', 'job_title', 'Y', 'start_date', current_date));
    -- (idempotent: the application is already hired, so this returns instead of inserting)
  exception when unique_violation then null;
  end;
end $$;
reset role;
set app.test_uid = '';
delete from public.application_events where application_id = '90000000-0000-0000-0000-0000000000d1';
delete from public.applications where id = '90000000-0000-0000-0000-0000000000d1';
delete from public.candidates where id = '80000000-0000-0000-0000-0000000000d1';
delete from public.jobs where id = '70000000-0000-0000-0000-0000000000d1';

-- ================================================================ 0040
-- Checklists: the holding default is the admins'; a company's first edit
-- copies it; checklists started after use the company list; running ones
-- keep their copy; retire hides a line; add_plan_task; cancel_departure;
-- the private-details line ticks itself.
do $$
begin
  assert (select count(*) from public.template_tasks tt join public.task_templates t on t.id = tt.template_id
          where t.company_id is null and t.kind = 'onboarding' and tt.archived_at is null) = 11, 'the richer onboarding default';
  assert (select count(*) from public.template_tasks tt join public.task_templates t on t.id = tt.template_id
          where t.company_id is null and t.kind = 'offboarding' and tt.archived_at is null) = 8, 'the richer offboarding default';
  assert exists (select 1 from public.template_tasks where key = 'private_details'), 'keyed lines';
end $$;

-- Bea (Company HR in B, tasks.assign) may not touch the holding default.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare v_default uuid; r jsonb; v_company uuid; v_line uuid;
begin
  select id into v_default from public.task_templates where company_id is null and kind = 'onboarding' and active limit 1;
  begin
    perform public.upsert_template_task(jsonb_build_object('template_id', v_default, 'title', 'Not mine', 'owner_role', 'hr', 'phase_key', 'day_one'));
    raise exception 'FAIL: HR edited the holding default';
  exception when insufficient_privilege then null;
  end;
  -- Her first edit for B copies the default into a company template.
  r := public.company_template('10000000-0000-0000-0000-00000000000b', 'onboarding');
  assert (r->>'created')::boolean, 'the company copy is created on first ask: ' || r::text;
  v_company := (r->>'template_id')::uuid;
  assert (select count(*) from public.template_tasks where template_id = v_company and archived_at is null) = 11, 'the copy carries every default line';
  assert (select count(*) from public.template_tasks where template_id = v_default and archived_at is null) = 11, 'the default is untouched';
  r := public.company_template('10000000-0000-0000-0000-00000000000b', 'onboarding');
  assert not (r->>'created')::boolean and (r->>'template_id')::uuid = v_company, 'a second ask returns the same copy';
  -- A new line for B, a refused phase, a refused owner.
  r := public.upsert_template_task(jsonb_build_object('template_id', v_company, 'title', 'Parking badge issued', 'owner_role', 'it',
    'phase_key', 'before_start', 'due_offset_days', -1, 'critical', false));
  v_line := (r->>'id')::uuid;
  assert (select sort_order from public.template_tasks where id = v_line) > (select max(sort_order) from public.template_tasks where template_id = v_company and id <> v_line),
    'a new line lands at the end';
  begin
    perform public.upsert_template_task(jsonb_build_object('template_id', v_company, 'title', 'Wrong phase', 'owner_role', 'hr', 'phase_key', 'last_day'));
    raise exception 'FAIL: an offboarding phase on an onboarding checklist';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.upsert_template_task(jsonb_build_object('template_id', v_company, 'title', 'Wrong owner', 'owner_role', 'ceo', 'phase_key', 'day_one'));
    raise exception 'FAIL: an unknown owner accepted';
  exception when invalid_parameter_value then null;
  end;
  -- Edit the line; the key of a default line never changes.
  r := public.upsert_template_task(jsonb_build_object('template_id', v_company, 'id', v_line, 'title', 'Parking badge and key issued', 'owner_role', 'it',
    'phase_key', 'before_start', 'due_offset_days', -2, 'critical', true));
  assert (select title from public.template_tasks where id = v_line) = 'Parking badge and key issued' and (select critical from public.template_tasks where id = v_line), 'the line is edited';
  -- Reorder: must list every live line once.
  begin
    perform public.reorder_template_tasks(v_company, array[v_line]);
    raise exception 'FAIL: a partial order accepted';
  exception when invalid_parameter_value then null;
  end;
  r := public.reorder_template_tasks(v_company, array[v_line] || (select array_agg(id order by sort_order) from public.template_tasks where template_id = v_company and archived_at is null and id <> v_line));
  assert (select sort_order from public.template_tasks where id = v_line) = 10, 'the moved line is first';
end $$;
reset role;

-- A checklist started now in B uses the company list; one started earlier is untouched by later edits.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; v_plan uuid; v_company uuid; v_line uuid; v_person uuid;
begin
  select id into v_company from public.task_templates where company_id = '10000000-0000-0000-0000-00000000000b' and kind = 'onboarding' and active;
  r := public.create_employee(jsonb_build_object('full_name', 'Checked Starter', 'work_email', 'checked@b.test',
    'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date + 5));
  v_plan := (r->>'plan_id')::uuid;
  v_person := (r->>'person_id')::uuid;
  assert (select template_id from public.plans where id = v_plan) = v_company, 'the company template is used';
  assert (select count(*) from public.plan_tasks where plan_id = v_plan) = 12, 'eleven default lines plus the parking badge';
  assert exists (select 1 from public.plan_tasks where plan_id = v_plan and title = 'Parking badge and key issued' and critical), 'the edited line is on the checklist';
  assert (select task_key from public.plan_tasks where plan_id = v_plan and title = 'Personal, ID and bank details collected') = 'private_details', 'keys are copied';
  -- Retire the badge line: the running checklist keeps it, a new one does not.
  select id into v_line from public.template_tasks where template_id = v_company and title = 'Parking badge and key issued';
  perform public.retire_template_task(v_line);
  assert exists (select 1 from public.plan_tasks where plan_id = v_plan and template_task_id = v_line), 'a running checklist keeps its copy';
  r := public.create_employee(jsonb_build_object('full_name', 'Later Starter', 'work_email', 'later@b.test',
    'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date + 5));
  assert (select count(*) from public.plan_tasks where plan_id = (r->>'plan_id')::uuid) = 11, 'a retired line is gone from new checklists';
  -- A keyed line retired and added back under its title regains the key.
  select id into v_line from public.template_tasks where template_id = v_company and key = 'welcome_note' and archived_at is null;
  perform public.retire_template_task(v_line);
  r := public.upsert_template_task(jsonb_build_object('template_id', v_company, 'title', 'Welcome note sent with policies', 'owner_role', 'hr', 'phase_key', 'before_start', 'due_offset_days', -2));
  assert (select key from public.template_tasks where id = (r->>'id')::uuid) = 'welcome_note', 'the re-added line regains its key';
  -- The one-off task on one person's checklist; the phase follows the date.
  r := public.add_plan_task(v_plan, 'Bring the signed NDA', 'employee', current_date + 5, false);
  assert (r->>'phase_key') = 'day_one', 'a task due on the start date is day one: ' || r::text;
  r := public.add_plan_task(v_plan, 'Desk set up', 'it', current_date + 3, true);
  assert (r->>'phase_key') = 'before_start', 'a task due before the start is before start';
  assert (select count(*) from public.plan_tasks where plan_id = v_plan) = 14, 'the one-off tasks are on this checklist only';
  begin
    perform public.add_plan_task(v_plan, 'x', 'hr');
    raise exception 'FAIL: a one-letter task accepted';
  exception when invalid_parameter_value then null;
  end;
  -- The private-details line ticks itself once both fields are on file.
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'private_details') = 'open', 'open until the details land';
  insert into public.person_private_details (person_id, national_id) values (v_person, '0101990450077');
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'private_details') = 'open', 'the ID alone is not enough';
  update public.person_private_details set bank_account = '{"bank": "NLB", "account_number": "210000000000777"}'::jsonb where person_id = v_person;
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'private_details') = 'done', 'both on file → done by itself';
  assert (select done_by from public.plan_tasks where plan_id = v_plan and task_key = 'private_details') = '20000000-0000-0000-0000-000000000005', 'done by whoever filled them';
end $$;
reset role;

-- Omar (no tasks.assign) may not add a task or shape a checklist. He cannot
-- even read the plan, so its id is looked up first and handed in.
select set_config('app.smoke_plan', (select pl.id::text from public.plans pl join public.people p on p.id = pl.person_id where p.work_email = 'checked@b.test'), false);
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare v_plan uuid := current_setting('app.smoke_plan')::uuid;
begin
  begin
    perform public.add_plan_task(v_plan, 'Sneaky task', 'hr');
    raise exception 'FAIL: a task added without tasks.assign';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.company_template('10000000-0000-0000-0000-00000000000b', 'onboarding');
    raise exception 'FAIL: a template copied without tasks.assign';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- cancel_departure: the dates go, the plan is cancelled, a later schedule starts afresh; refused after former.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; v_period uuid; v_plan uuid; v_plan2 uuid;
begin
  select ep.id into v_period from public.employment_periods ep join public.people p on p.id = ep.person_id where p.work_email = 'checked@b.test';
  begin
    perform public.cancel_departure(v_period);
    raise exception 'FAIL: cancelled a departure that was never scheduled';
  exception when invalid_parameter_value then null;
  end;
  r := public.schedule_departure(v_period, current_date + 30, current_date + 25, 'Moving on');
  v_plan := (r->>'plan_id')::uuid;
  assert (select count(*) from public.plan_tasks where plan_id = v_plan) = 8, 'the richer offboarding default: ' || r::text;
  r := public.cancel_departure(v_period, 'Changed their mind');
  assert (r->>'status') = 'employed', 'employed again: ' || r::text;
  assert (select end_date from public.employment_periods where id = v_period) is null
     and (select last_working_date from public.employment_periods where id = v_period) is null, 'the dates are cleared';
  assert (select status from public.plans where id = v_plan) = 'cancelled'
     and (select cancelled_reason from public.plans where id = v_plan) = 'Changed their mind', 'the plan is cancelled with the reason';
  assert (select reason from public.employment_departure_details where employment_period_id = v_period) = 'Moving on', 'the departure details stay for history';
  -- Scheduling again starts a fresh plan; the cancelled one stays on record.
  r := public.schedule_departure(v_period, current_date + 40, null, 'Really moving on');
  v_plan2 := (r->>'plan_id')::uuid;
  assert v_plan2 <> v_plan and not (r->>'already_scheduled')::boolean, 'a fresh plan after a cancel';
  -- After former the way back is a rehire, not a cancel.
  perform public.complete_departure(v_period);
  begin
    perform public.cancel_departure(v_period);
    raise exception 'FAIL: cancelled a departure after former';
  exception when invalid_parameter_value then null;
  end;
end $$;
reset role;
select set_config('app.smoke_period', (select ep.id::text from public.employment_periods ep join public.people p on p.id = ep.person_id where p.work_email = 'later@b.test'), false);
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar: no departure.start (and cannot read the period)
set role authenticated;
do $$
declare v_period uuid := current_setting('app.smoke_period')::uuid;
begin
  begin
    perform public.cancel_departure(v_period);
    raise exception 'FAIL: cancelled without departure.start';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- ================================================================ 0041
-- The handover: one send per recipient per event with exactly that
-- recipient's fields; sensitive fields only to trusted recipients and only
-- placed by those who may see them; missing fields and addresses named;
-- resend after filling; manual green; the checklist line ticks itself; a
-- cancelled departure cancels pending sends; IT requests notify.
do $$
begin
  assert (select count(*) from public.handover_recipients where company_id is null and active) = 3, 'three holding defaults';
  assert (select count(*) from jsonb_array_elements(public.handover_fields())) = 20, 'the catalogue';
end $$;

-- Company B: an IT owner and an IT address; Bea (Company HR: tasks.assign + personal.view, no salary.view).
insert into public.workflow_owners (company_id, role_key, person_id) values
  ('10000000-0000-0000-0000-00000000000b', 'it_owner', '20000000-0000-0000-0000-000000000005')
  on conflict (company_id, role_key) do update set person_id = excluded.person_id;
update public.companies set it_notification_email = 'it@b.test' where id = '10000000-0000-0000-0000-00000000000b';

set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; v_acc uuid;
begin
  -- Bea may not touch the holding default.
  begin
    perform public.save_handover_recipient(jsonb_build_object('label', 'Nope', 'kind', 'email', 'email', 'x@y.test'));
    raise exception 'FAIL: HR changed the holding default';
  exception when insufficient_privilege then null;
  end;
  -- Bea configures B's own accountant with the bank account (personal.view: allowed) …
  r := public.save_handover_recipient(jsonb_build_object('company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'Accountant B',
    'kind', 'email', 'email', 'books@b.test', 'events', jsonb_build_array('hire_confirmed', 'marked_former'),
    'fields', jsonb_build_array('name', 'national_id', 'bank_account', 'start_date'), 'trusted', true));
  v_acc := (r->>'id')::uuid;
  -- … but not the salary (no salary.view) …
  begin
    perform public.save_handover_recipient(jsonb_build_object('id', v_acc, 'company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'Accountant B',
      'kind', 'email', 'email', 'books@b.test', 'events', jsonb_build_array('hire_confirmed'),
      'fields', jsonb_build_array('name', 'national_id', 'bank_account', 'salary'), 'trusted', true));
    raise exception 'FAIL: salary placed without salary.view';
  exception when insufficient_privilege then
    if sqlerrm not like '%salary.view%' then raise; end if;
  end;
  -- … and never a sensitive field on an untrusted recipient.
  begin
    perform public.save_handover_recipient(jsonb_build_object('company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'Loose',
      'kind', 'email', 'email', 'loose@b.test', 'events', jsonb_build_array('hire_confirmed'),
      'fields', jsonb_build_array('national_id'), 'trusted', false));
    raise exception 'FAIL: a sensitive field on an untrusted recipient';
  exception when invalid_parameter_value then null;
  end;
  -- IT for B: the role, with the national ID configured on an untrusted recipient is refused; without it fine.
  r := public.save_handover_recipient(jsonb_build_object('company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'IT B',
    'kind', 'role', 'role_key', 'it_owner', 'events', jsonb_build_array('hire_confirmed', 'departure_scheduled'),
    'fields', jsonb_build_array('name', 'work_email', 'position', 'start_date', 'equipment_held'), 'trusted', false));
  -- The manager pseudo-role.
  r := public.save_handover_recipient(jsonb_build_object('company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'Manager B',
    'kind', 'role', 'role_key', 'manager', 'events', jsonb_build_array('hire_confirmed'),
    'fields', jsonb_build_array('name', 'position'), 'trusted', false));
  begin
    perform public.save_handover_recipient(jsonb_build_object('company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'Bad role',
      'kind', 'role', 'role_key', 'ceo', 'events', jsonb_build_array('hire_confirmed'), 'fields', jsonb_build_array('name')));
    raise exception 'FAIL: an unknown role accepted';
  exception when invalid_parameter_value then null;
  end;
end $$;
reset role;

-- A hire in B with no bank account: one send per recipient; the accountant is missing the bank account,
-- IT is pending with only its fields, the manager (none set) is missing the address.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; v_person uuid; v_plan uuid; v_period uuid; s record;
begin
  r := public.create_employee(jsonb_build_object('full_name', 'Handed Over', 'work_email', 'handed@b.test',
    'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Analyst', 'start_date', current_date + 10,
    'private', jsonb_build_object('national_id', '0101990450088')));
  v_person := (r->>'person_id')::uuid; v_plan := (r->>'plan_id')::uuid; v_period := (r->>'employment_period_id')::uuid;
  assert (select count(*) from public.handover_sends where plan_id = v_plan and event = 'hire_confirmed') = 3, 'one send per recipient';
  select * into s from public.handover_sends where plan_id = v_plan and recipient_label = 'Accountant B';
  assert s.status = 'missing' and s.missing = array['Bank account'], 'the accountant is missing the bank account: ' || s.missing::text;
  assert s.to_email = 'books@b.test', 'the address is resolved';
  assert s.fields ? 'national_id' and s.fields ? 'name' and not (s.fields ? 'salary') and not (s.fields ? 'work_email'),
    'exactly the accountant''s fields: ' || s.fields::text;
  assert (s.fields -> 'national_id' ->> 'value') = '0101990450088', 'the value itself';
  select * into s from public.handover_sends where plan_id = v_plan and recipient_label = 'IT B';
  assert s.status = 'pending' and s.to_email = 'it@b.test', 'IT goes to the company IT address: ' || s.to_email;
  assert not (s.fields ? 'national_id'), 'IT never gets the national ID';
  assert s.stripped = '{}', 'nothing was configured that IT may not have';
  select * into s from public.handover_sends where plan_id = v_plan and recipient_label = 'Manager B';
  assert s.status = 'missing' and s.missing[1] = 'Address for Manager B', 'no manager set → address missing: ' || s.missing::text;
  -- The checklist line is not ticked while anything is red.
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'handover') = 'open', 'handover line open';
  -- Fill the bank account and resend: pending now, with the value.
  update public.person_private_details set bank_account = '{"bank": "NLB", "account_number": "210000000000888"}'::jsonb where person_id = v_person;
  r := public.resend_handover((select id from public.handover_sends where plan_id = v_plan and recipient_label = 'Accountant B'));
  assert (r->>'status') = 'pending', 'resend after filling: ' || r::text;
  select * into s from public.handover_sends where plan_id = v_plan and recipient_label = 'Accountant B';
  assert (s.fields -> 'bank_account' ->> 'value') = 'NLB · 210000000000888' and s.missing = '{}', 'the snapshot carries the account now';
  -- Set a manager, resend: the manager's address resolves.
  perform public.correct_employment(v_period, current_date + 10, null, null, null, jsonb_build_object('manager_id', '20000000-0000-0000-0000-000000000005'));
  r := public.resend_handover((select id from public.handover_sends where plan_id = v_plan and recipient_label = 'Manager B'));
  assert (r->>'status') = 'pending' and (select to_email from public.handover_sends where plan_id = v_plan and recipient_label = 'Manager B') = 'bea@b.test',
    'the manager''s address resolves: ' || r::text;
  -- Mark the three as sent by hand: the line ticks itself.
  perform public.mark_handover_sent(id) from public.handover_sends where plan_id = v_plan and event = 'hire_confirmed';
  assert (select count(*) from public.handover_sends where plan_id = v_plan and event = 'hire_confirmed' and status = 'manual') = 3, 'all manual';
  assert (select marked_by from public.handover_sends where plan_id = v_plan and recipient_label = 'IT B') = '20000000-0000-0000-0000-000000000005', 'who marked it';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'handover') = 'done', 'the handover line ticked itself';
  -- Retry is only for a failed send.
  begin
    perform public.retry_handover((select id from public.handover_sends where plan_id = v_plan and recipient_label = 'IT B'));
    raise exception 'FAIL: retried a send that had not failed';
  exception when invalid_parameter_value then null;
  end;
  -- Departure scheduled: IT hears with the equipment held (none); cancelling cancels the pending send.
  r := public.schedule_departure(v_period, current_date + 40, current_date + 38, 'Leaving');
  assert (select count(*) from public.handover_sends where event = 'departure_scheduled' and person_id = v_person) = 1, 'IT alone hears of the departure';
  assert (select status from public.handover_sends where event = 'departure_scheduled' and person_id = v_person) = 'pending', 'pending';
  perform public.cancel_departure(v_period, 'Stays');
  assert (select status from public.handover_sends where event = 'departure_scheduled' and person_id = v_person) = 'cancelled', 'a cancelled departure cancels its sends';
  -- Marked former: the accountant hears (with the end date).
  r := public.schedule_departure(v_period, current_date + 40, current_date + 38, 'Leaving after all');
  perform public.complete_departure(v_period);
  select * into s from public.handover_sends where event = 'marked_former' and person_id = v_person and recipient_label = 'Accountant B';
  assert s.status = 'pending' and (s.fields -> 'start_date' ->> 'value') is not null, 'the accountant hears of the leaver: ' || s.fields::text;
end $$;
reset role;

-- Omar (no tasks.assign in B, no tasks.view) sees no sends and may not work them.
select set_config('app.smoke_send', (select s.id::text from public.handover_sends s join public.people p on p.id = s.person_id where p.work_email = 'handed@b.test' limit 1), false);
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
begin
  assert (select count(*) from public.handover_sends s join public.people p on p.id = s.person_id where p.work_email = 'handed@b.test') = 0, 'sends are HR''s to read';
  begin
    perform public.mark_handover_sent(current_setting('app.smoke_send')::uuid);
    raise exception 'FAIL: worked a send without tasks.assign';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '';

-- The audit never carries a snapshot value or an address.
do $$
begin
  assert (select count(*) from public.activity_log where entity_type = 'handover_sends') > 0, 'sends are audited';
  assert not exists (select 1 from public.activity_log where entity_type in ('handover_sends', 'handover_recipients')
                     and (coalesce(after::text, '') like '%210000000000888%' or coalesce(after::text, '') like '%0101990450088%'
                          or coalesce(after::text, '') like '%books@b.test%')),
    'the audit never carries a value or an address';
end $$;

-- IT requests join the notification layer: created → the IT owner at the company IT address.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex, HR-ish in B via the 0026 grant (employment.edit) — requests need it.view? use admin
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
insert into public.it_requests (company_id, person_id, kind, title)
  values ('10000000-0000-0000-0000-00000000000b', (select id from public.people where work_email = 'nora@b.test'), 'manual', 'Second monitor');
reset role;
set app.test_uid = '';
do $$
declare n record;
begin
  select * into n from public.notifications where kind = 'it.requested' order by created_at desc limit 1;
  assert n.person_id = '20000000-0000-0000-0000-000000000005', 'the IT owner is told';
  assert n.email_to = 'it@b.test', 'at the company IT address: ' || coalesce(n.email_to, 'null');
  assert n.title like 'IT request for Nora Newhire: Second monitor', 'the title: ' || n.title;
end $$;

-- ================================================================ 0042
-- Equipment for the holding: the pool is seen and worked by anyone with
-- the IT capabilities anywhere and goes to anyone employed anywhere; a
-- company asset keeps its gate; the leaver's return tasks include the
-- pool; the starter kit opens a request per hire and ticks the line; the
-- forms are queued for the server and the signed return ticks its line.
insert into public.assets (id, company_id, asset_tag, type_key, model) values
  ('a0000000-0000-0000-0000-0000000000f1', null, 'POOL-001', 'laptop', 'ThinkPad X1'),
  ('a0000000-0000-0000-0000-0000000000f2', '10000000-0000-0000-0000-00000000000a', 'A-ONLY-01', 'laptop', 'MacBook');

-- Bea (Company HR in B: no IT capabilities) sees neither; give her IT in B.
insert into public.grant_capabilities (grant_id, capability_key) values
  ('40000000-0000-0000-0000-000000000003', 'it.view'),
  ('40000000-0000-0000-0000-000000000003', 'it.assign'),
  ('40000000-0000-0000-0000-000000000003', 'it.complete');
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; v_assignment uuid; v_alex uuid := '20000000-0000-0000-0000-000000000001';
begin
  assert (select count(*) from public.assets where asset_tag = 'POOL-001') = 1, 'the pool is visible with it.view anywhere';
  assert (select count(*) from public.assets where asset_tag = 'A-ONLY-01') = 0, 'a company asset stays behind its gate';
  -- The pool laptop goes to Alex, employed in A, though Bea holds IT only in B.
  r := public.reserve_asset('a0000000-0000-0000-0000-0000000000f1', v_alex, 'From the pool');
  v_assignment := (r->>'assignment_id')::uuid;
  perform public.issue_asset(v_assignment);
  assert (select status from public.assets where id = 'a0000000-0000-0000-0000-0000000000f1') = 'assigned', 'issued from the pool';
  -- A company asset of A is not hers to work.
  begin
    perform public.reserve_asset('a0000000-0000-0000-0000-0000000000f2', v_alex);
    raise exception 'FAIL: worked a company asset without it.assign there';
  exception when insufficient_privilege then null;
  end;
  -- A pool asset cannot go to someone with no employment.
  begin
    perform public.reserve_asset('a0000000-0000-0000-0000-0000000000f1', '20000000-0000-0000-0000-0000000000c1');
    raise exception 'FAIL: reserved an already-assigned asset';
  exception when raise_exception then
    if sqlerrm not like '%only an available asset%' then raise; end if;
  end;
end $$;
reset role;
-- The handover form is queued for the server (the queue is read by tasks.view / it.view in the person's company; Bea has neither in A).
do $$
begin
  assert exists (select 1 from public.generated_documents where kind = 'equipment_handover' and person_id = '20000000-0000-0000-0000-000000000001' and status = 'pending'),
    'the handover form is queued on issue';
end $$;

-- The pool asset can be added to the register by anyone with it.assign anywhere; the tag is unique within the pool.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
insert into public.assets (company_id, asset_tag, type_key, model) values (null, 'POOL-002', 'monitor', 'Dell 27');
do $$
begin
  begin
    insert into public.assets (company_id, asset_tag, type_key) values (null, 'POOL-002', 'monitor');
    raise exception 'FAIL: duplicate pool tag accepted';
  exception when unique_violation then null;
  end;
  -- The same tag may exist in a company (nulls-not-distinct only ties the pool to itself).
  insert into public.assets (company_id, asset_tag, type_key) values ('10000000-0000-0000-0000-00000000000b', 'POOL-002', 'monitor');
end $$;
reset role;

-- Starter kit: the holding default when the company has none; the company's own when set.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.starter_kit('10000000-0000-0000-0000-00000000000b');
  assert jsonb_array_length(r->'items') = 7 and not (r->>'own')::boolean, 'the holding default kit: ' || r::text;
  r := public.set_starter_kit('10000000-0000-0000-0000-00000000000b', array['Laptop', 'Badge', ' Headset ', 'Laptop']);
  assert r->'items' = '["Badge", "Headset", "Laptop"]'::jsonb, 'trimmed, deduplicated, sorted: ' || r::text;
  r := public.starter_kit('10000000-0000-0000-0000-00000000000b');
  assert (r->>'own')::boolean, 'the company has its own kit now';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar: no it.assign
set role authenticated;
do $$
begin
  begin
    perform public.set_starter_kit('10000000-0000-0000-0000-00000000000b', array['Nothing']);
    raise exception 'FAIL: kit set without it.assign';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- A hire in B opens the kit request with B's three items; issuing them all ticks the line.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; v_plan uuid; v_person uuid; v_req record;
begin
  r := public.create_employee(jsonb_build_object('full_name', 'Kit Starter', 'work_email', 'kit@b.test',
    'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date + 5));
  v_plan := (r->>'plan_id')::uuid; v_person := (r->>'person_id')::uuid;
  select * into v_req from public.it_requests where person_id = v_person and kind = 'onboarding';
  assert v_req.id is not null and jsonb_array_length(v_req.requested_systems) = 3, 'the kit request carries the company items: ' || coalesce(v_req.requested_systems::text, 'none');
  assert v_req.plan_task_id = (select id from public.plan_tasks where plan_id = v_plan and task_key = 'starter_kit'), 'tied to the starter kit line';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'starter_kit') = 'open', 'line open';
  -- The handover's starter_kit value reads the kit.
  assert app.handover_value('starter_kit', v_person, (r->>'employment_period_id')::uuid) = 'Badge —, Headset —, Laptop —', 'kit summary: ' || coalesce(app.handover_value('starter_kit', v_person, (r->>'employment_period_id')::uuid), 'null');
  -- Issue the badge, then the laptop with the pool monitor as the asset (a registered item), then add and issue an extra.
  r := public.issue_kit_item(v_req.id, 0);
  assert not (r->>'done')::boolean, 'one of three';
  assert (select status from public.it_requests where id = v_req.id) = 'in_progress', 'the request is in progress';
  r := public.issue_kit_item(v_req.id, 2, (select id from public.assets where asset_tag = 'POOL-002' and company_id is null));
  assert (select status from public.assets where asset_tag = 'POOL-002' and company_id is null) = 'assigned', 'naming an asset issues it to the person';
  begin
    perform public.issue_kit_item(v_req.id, 0);
    raise exception 'FAIL: issued an item twice';
  exception when invalid_parameter_value then null;
  end;
  r := public.add_kit_item(v_req.id, 'Docking station');
  assert jsonb_array_length(r->'items') = 4, 'the extra item';
  r := public.issue_kit_item(v_req.id, 1);
  assert not (r->>'done')::boolean, 'the extra still open';
  r := public.issue_kit_item(v_req.id, 3);
  assert (r->>'done')::boolean, 'every item issued';
  assert (select status from public.it_requests where id = v_req.id) = 'done', 'the request is done';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'starter_kit') = 'done', 'the line ticked itself';
  assert app.handover_value('starter_kit', v_person, (r->>'employment_period_id')::uuid) like '%Docking station ✓%', 'the summary shows the ticks';
end $$;
reset role;

-- Departure: the return tasks list the pool laptop Alex holds; the return form is queued; the signed scan ticks the line.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb; v_plan uuid; v_alex uuid := '20000000-0000-0000-0000-000000000001'; v_doc uuid; v_period uuid := '30000000-0000-0000-0000-000000000001';
begin
  r := public.schedule_departure(v_period, current_date + 60, current_date + 58, 'Leaving');
  v_plan := (r->>'plan_id')::uuid;
  assert exists (select 1 from public.plan_tasks where plan_id = v_plan and asset_id = 'a0000000-0000-0000-0000-0000000000f1'), 'the pool laptop is on the return list';
  assert exists (select 1 from public.generated_documents where kind = 'equipment_return' and person_id = v_alex and plan_id = v_plan and status = 'pending'), 'the return form is queued';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'return_form') = 'open', 'the return-form line is open';
end $$;
reset role;
-- The server records the generated file (service role), then HR uploads the signed scan as version 2.
do $$
declare q uuid; r jsonb; v_alex uuid := '20000000-0000-0000-0000-000000000001'; d jsonb; v_doc uuid; v_plan uuid;
begin
  select id into q from public.generated_documents where kind = 'equipment_return' and person_id = v_alex and status = 'pending';
  d := public.equipment_form_data(q);
  assert d->'person'->>'name' = 'Alex Director' and jsonb_array_length(d->'assets') = 1 and d->'assets'->0->>'tag' = 'POOL-001', 'the form data: ' || d::text;
  r := public.record_generated_document(q, '10000000-0000-0000-0000-00000000000a/' || v_alex || '/return.pdf', 12345, 'Equipment return form');
  v_doc := (r->>'document_id')::uuid;
  assert (select status from public.generated_documents where id = q) = 'done', 'the queue row is done';
  assert (select category_key from public.documents where id = v_doc) = 'equipment_return' and (select version from public.documents where id = v_doc) = 1, 'version 1 recorded';
  assert (select uploaded_by from public.documents where id = v_doc) = '20000000-0000-0000-0000-000000000004', 'the requester is the uploader';
  -- A regenerated form archives the old one and is version 1 again — never mistaken for the signed scan.
  update public.generated_documents set status = 'pending', dedupe_key = dedupe_key || ':again' where id = q;
  r := public.record_generated_document(q, '10000000-0000-0000-0000-00000000000a/' || v_alex || '/return2.pdf', 12345, 'Equipment return form');
  assert (select archived_at from public.documents where id = v_doc) is not null, 'the previous unsigned form is archived';
  v_doc := (r->>'document_id')::uuid;
  assert (select version from public.documents where id = v_doc) = 1, 'the fresh form is version 1';
  perform set_config('app.smoke_return_doc', v_doc::text, false);
end $$;
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
insert into public.documents (company_id, person_id, category_key, title, storage_path, visibility, supersedes_id)
  values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000001', 'equipment_return', 'Equipment return form (signed)',
          '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000001/return-signed.pdf', 'person_and_hr',
          current_setting('app.smoke_return_doc')::uuid);
do $$
declare v_plan uuid;
begin
  select id into v_plan from public.plans where employment_period_id = '30000000-0000-0000-0000-000000000001' and kind = 'offboarding' and status = 'in_progress';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'return_form') = 'done', 'the signed scan ticked the line';
  -- Undo the departure so the fixtures stay as later blocks expect.
  perform public.cancel_departure('30000000-0000-0000-0000-000000000001', 'smoke');
end $$;
reset role;
set app.test_uid = '';
delete from public.grant_capabilities where grant_id = '40000000-0000-0000-0000-000000000003' and capability_key in ('it.view', 'it.assign', 'it.complete');

-- ================================================================ 0043
-- The policy library, text policies, the self-ticking "Policies
-- acknowledged" line, first-day details and the welcome note.
do $$
begin
  assert (select count(*) from public.policies where company_id is null and status = 'draft' and body is not null
          and title in ('Code of Conduct', 'Time off & leave', 'Remote & hybrid work', 'IT & data security', 'Anti-harassment & equal opportunity', 'Expenses & reimbursement')) = 6,
    'the six drafts are seeded holding-wide with a body';
end $$;

-- Ada (admin) publishes a holding-wide text policy without a file; a policy with neither is refused.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
declare v_code uuid; v_empty uuid; r jsonb;
begin
  select id into v_code from public.policies where company_id is null and title = 'Code of Conduct';
  r := public.publish_policy(v_code);
  assert (r->>'status') = 'published' and (r->>'version')::int = 1, 'a text policy publishes without a file: ' || r::text;
  insert into public.policies (company_id, title) values (null, 'Empty policy') returning id into v_empty;
  begin
    perform public.publish_policy(v_empty);
    raise exception 'FAIL: published with neither text nor file';
  exception when raise_exception then
    if sqlerrm not like '%Attach the policy document or write its text%' then raise; end if;
  end;
  -- A new version of a text policy needs new text.
  begin
    perform public.publish_policy(v_code);
    raise exception 'FAIL: republished with nothing new';
  exception when raise_exception then
    if sqlerrm not like '%new file or write the new text%' then raise; end if;
  end;
  r := public.publish_policy(v_code, null, null, null, 'Version two of the code.');
  assert (r->>'version')::int = 2 and (select body from public.policies where id = v_code) = 'Version two of the code.', 'a new body is a new version';
  -- A published policy's text is not edited in place.
  begin
    update public.policies set body = 'sneaky' where id = v_code;
    raise exception 'FAIL: edited a published policy''s text in place';
  exception when raise_exception then
    if sqlerrm not like '%Publish a new version%' then raise; end if;
  end;
  delete from public.policies where id = v_empty;
end $$;
reset role;

-- First-day details: Bea (tasks.assign in B) sets B's; the holding's is the fallback elsewhere.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
select public.set_first_day_details((select id from public.companies where kind = 'holding' limit 1), '{"where": "Reception, floor 2", "when": "09:00", "ask_for": "Reception", "bring": "ID card"}'::jsonb);
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.first_day_details('10000000-0000-0000-0000-00000000000b');
  assert not (r->>'own')::boolean and r->'details'->>'where' = 'Reception, floor 2', 'the holding fallback: ' || r::text;
  r := public.set_first_day_details('10000000-0000-0000-0000-00000000000b', '{"where": "B Office, Skopje", "when": "  08:30 ", "ask_for": "", "bring": "Passport"}'::jsonb);
  assert r->'details' = '{"bring": "Passport", "when": "08:30", "where": "B Office, Skopje"}'::jsonb, 'trimmed, blanks dropped: ' || r::text;
  r := public.first_day_details('10000000-0000-0000-0000-00000000000b');
  assert (r->>'own')::boolean, 'B has its own now';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
begin
  begin
    perform public.set_first_day_details('10000000-0000-0000-0000-00000000000b', '{"where": "x"}'::jsonb);
    raise exception 'FAIL: first-day details set without tasks.assign';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- The welcome note for a hire in B: the text, the send, the tick; then the acknowledgement tick.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; n jsonb; v_plan uuid; v_person uuid; v_period uuid;
begin
  r := public.create_employee(jsonb_build_object('full_name', 'Welcome Starter', 'preferred_name', 'Wel', 'work_email', 'welcome@b.test',
    'personal_email', 'wel.home@example.test', 'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Analyst',
    'department_id', 'd0000000-0000-0000-0000-0000000000b1', 'manager_id', '20000000-0000-0000-0000-000000000005', 'start_date', current_date + 14));
  v_plan := (r->>'plan_id')::uuid; v_person := (r->>'person_id')::uuid; v_period := (r->>'employment_period_id')::uuid;
  n := public.welcome_note_text(v_plan);
  assert (n->>'subject') = 'Welcome to ' || (select name from public.companies where id = '10000000-0000-0000-0000-00000000000b') || ', Wel', 'the subject: ' || (n->>'subject');
  assert (n->>'text') like 'Dear Wel,%' and (n->>'text') like '%as Analyst in Operations B, starting on ' || to_char(current_date + 14, 'DD FMMonth YYYY') || '. Your manager%'
     and (n->>'text') like '%Your manager will be Bea HR%', 'the greeting and the facts: ' || (n->>'text');
  assert (n->>'text') like '%Where: B Office, Skopje%' and (n->>'text') like '%Please bring: Passport%', 'the first-day details';
  assert (n->>'text') like '%• Code of Conduct — How we treat each other%', 'the published policies are listed';
  assert (n->>'text') not like '%Time off & leave%', 'drafts are not';
  assert (n->>'sent_at') is null, 'not sent yet';
  -- Send to the personal address (the default).
  r := public.send_welcome_note(v_plan);
  assert (r->>'to') = 'wel.home@example.test' and (r->>'status') = 'pending', 'sent to the personal address: ' || r::text;
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'welcome_note') = 'done', 'the welcome line ticked';
  assert (select welcome_sent_to from public.plans where id = v_plan) = 'personal', 'the plan remembers';
  -- Again, to the work address.
  r := public.send_welcome_note(v_plan, 'work');
  assert (r->>'to') = 'welcome@b.test', 'the work address on demand';
  -- The policies line: open until the last applicable policy is acknowledged.
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'policies') = 'open', 'policies line open';
end $$;
reset role;
-- The notifications (self-only RLS: read as superuser) and the PDF queue; its data carries the note.
do $$
declare q uuid; d jsonb; v_person uuid := (select id from public.people where work_email = 'welcome@b.test');
begin
  assert exists (select 1 from public.notifications where person_id = v_person and kind = 'welcome.note' and email_to = 'wel.home@example.test' and email_status = 'pending'),
    'a notification row carries the note to the personal address';
  assert (select count(*) from public.notifications where person_id = v_person and kind = 'welcome.note') = 2, 're-sending is allowed';
  select id into q from public.generated_documents where kind = 'welcome_note' and person_id = (select id from public.people where work_email = 'welcome@b.test') order by created_at desc limit 1;
  assert q is not null, 'the welcome note PDF is queued';
  d := public.welcome_note_data(q);
  assert (d->>'company') = (select name from public.companies where id = '10000000-0000-0000-0000-00000000000b') and (d->>'text') like 'Dear Wel,%', 'the PDF data: ' || left(d::text, 120);
end $$;

-- No personal address: skipped, and said so.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
declare r jsonb; v_plan uuid;
begin
  r := public.create_employee(jsonb_build_object('full_name', 'No Address', 'company_id', '10000000-0000-0000-0000-00000000000b', 'job_title', 'Clerk', 'start_date', current_date + 3));
  v_plan := (r->>'plan_id')::uuid;
  r := public.send_welcome_note(v_plan);
  assert (r->>'status') = 'skipped' and (r->>'note') like 'No personal email%', 'no address → skipped and said: ' || r::text;
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'welcome_note') = 'done', 'still ticked — the note exists in the app and as a PDF';
end $$;
reset role;

-- The person acknowledges: a company policy counts only for that company; the holding's for everyone.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada publishes a B-only policy and an A-only one
set role authenticated;
do $$
declare v_b uuid; v_a uuid;
begin
  insert into public.policies (company_id, title, body) values ('10000000-0000-0000-0000-00000000000b', 'B house rules', 'Rules of B.') returning id into v_b;
  perform public.publish_policy(v_b);
  insert into public.policies (company_id, title, body) values ('10000000-0000-0000-0000-00000000000a', 'A house rules', 'Rules of A.') returning id into v_a;
  perform public.publish_policy(v_a);
end $$;
reset role;
-- Welcome Starter (no account in the smoke) — acknowledge as the service would for them: insert directly.
do $$
declare v_person uuid := (select id from public.people where work_email = 'welcome@b.test'); v_plan uuid;
begin
  select id into v_plan from public.plans where person_id = v_person and kind = 'onboarding';
  insert into public.policy_acknowledgements (policy_id, person_id, version)
    select id, v_person, version from public.policies where company_id is null and status = 'published';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'policies') = 'open', 'the holding''s alone is not enough while B''s is unread';
  insert into public.policy_acknowledgements (policy_id, person_id, version)
    select id, v_person, version from public.policies where company_id = '10000000-0000-0000-0000-00000000000b' and status = 'published';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'policies') = 'done', 'every applicable policy read → the line ticks (A''s does not apply)';
end $$;
-- A new version of a holding policy: the ticked line stays (history); a fresh checklist would wait for it.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
select public.publish_policy((select id from public.policies where company_id is null and title = 'Code of Conduct'), null, null, null, 'Version three.');
reset role;
set app.test_uid = '';
do $$
declare v_person uuid := (select id from public.people where work_email = 'welcome@b.test'); v_plan uuid;
begin
  select id into v_plan from public.plans where person_id = v_person and kind = 'onboarding';
  assert (select status from public.plan_tasks where plan_id = v_plan and task_key = 'policies') = 'done', 'a ticked line stays ticked';
end $$;
delete from public.policy_acknowledgements where policy_id in (select id from public.policies where title in ('B house rules', 'A house rules'));
delete from public.policies where title in ('B house rules', 'A house rules');

-- 0041's gate, reviewed: Omar with tasks.assign but no personal.view cannot redirect a trusted
-- recipient that carries the national ID; he may still change its label.
insert into public.access_grants (id, person_id, company_id)
  select '40000000-0000-0000-0000-000000000043', '20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000b'
  where not exists (select 1 from public.access_grants where person_id = '20000000-0000-0000-0000-000000000003' and company_id = '10000000-0000-0000-0000-00000000000b');
create temp table omar_b_added as
  select g.id as grant_id, c.cap as capability_key
  from public.access_grants g, (values ('tasks.view'), ('tasks.assign')) c(cap)
  where g.person_id = '20000000-0000-0000-0000-000000000003' and g.company_id = '10000000-0000-0000-0000-00000000000b'
    and not exists (select 1 from public.grant_capabilities gc where gc.grant_id = g.id and gc.capability_key = c.cap);
insert into public.grant_capabilities (grant_id, capability_key) select grant_id, capability_key from omar_b_added;
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare v_acc uuid; r jsonb;
begin
  select id into v_acc from public.handover_recipients where company_id = '10000000-0000-0000-0000-00000000000b' and label = 'Accountant B';
  begin
    perform public.save_handover_recipient(jsonb_build_object('id', v_acc, 'company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'Accountant B',
      'kind', 'email', 'email', 'thief@elsewhere.test', 'events', jsonb_build_array('hire_confirmed'),
      'fields', jsonb_build_array('name', 'national_id', 'bank_account', 'start_date'), 'trusted', true));
    raise exception 'FAIL: redirected sensitive fields without personal.view';
  exception when insufficient_privilege then
    if sqlerrm not like '%changing who receives it%' then raise; end if;
  end;
  r := public.save_handover_recipient(jsonb_build_object('id', v_acc, 'company_id', '10000000-0000-0000-0000-00000000000b', 'label', 'Accountant B (books)',
    'kind', 'email', 'email', 'books@b.test', 'events', jsonb_build_array('hire_confirmed'),
    'fields', jsonb_build_array('name', 'national_id', 'bank_account', 'start_date'), 'trusted', true));
  assert (select label from public.handover_recipients where id = v_acc) = 'Accountant B (books)', 'the label may change with the target kept';
end $$;
reset role;
set app.test_uid = '';
delete from public.grant_capabilities gc using omar_b_added a where gc.grant_id = a.grant_id and gc.capability_key = a.capability_key;
drop table omar_b_added;
delete from public.access_grants where id = '40000000-0000-0000-0000-000000000043';

-- ================================================================ 0044
-- Kudos values, a kudos recorded on someone's behalf, bonuses swept into
-- the next period, the net estimate (plan 051).
do $$
begin
  assert (select count(*) from public.kudos_values where active
          and name in ('Teamwork', 'Ownership', 'Customer focus', 'Innovation', 'Integrity')) = 5,
    'the five values are seeded';
end $$;

-- Alex (people.view in A) thanks Omar with a value; Omar, the receiver, may
-- neither edit nor record on anyone's behalf; a retired value is refused on
-- a new kudos and kept on an old one.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare v_team uuid := (select id from public.kudos_values where name = 'Teamwork');
begin
  insert into public.kudos (from_person_id, to_person_id, message, value_id)
    values ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'Smoke: great sprint', v_team);
  assert (select value_id from public.kudos where message = 'Smoke: great sprint') = v_team, 'a kudos carries its value';
  assert (select count(*) from jsonb_array_elements(public.dashboard_snapshot(30) -> 'kudos') k
          where k ->> 'message' = 'Smoke: great sprint' and k ->> 'value_name' = 'Teamwork') = 1,
    'the wall shows the value';
  -- Reviewed: the wall's insert cannot claim someone recorded it, nor pick its date.
  begin
    insert into public.kudos (from_person_id, to_person_id, message, posted_by)
      values ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'forged', '20000000-0000-0000-0000-000000000004');
    raise exception 'FAIL: posted_by set from the wall';
  exception when insufficient_privilege then null;
  end;
  -- Reviewed: HR fixing a typo on a kudos the giver posted themselves leaves it theirs.
  perform public.update_kudos((select id from public.kudos where message = 'Smoke: great sprint'), '{"message": "Smoke: great sprint!"}');
  assert (select posted_by from public.kudos where message = 'Smoke: great sprint!') is null, 'an edit does not claim the kudos';
  perform public.update_kudos((select id from public.kudos where message = 'Smoke: great sprint!'), '{"message": "Smoke: great sprint"}');
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
declare v_id uuid := (select id from public.kudos where message = 'Smoke: great sprint');
begin
  begin
    perform public.update_kudos(v_id, '{"message": "polished"}');
    raise exception 'FAIL: the receiver edited a kudos';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.record_kudos(jsonb_build_object('from_person_id', '20000000-0000-0000-0000-000000000001',
      'to_person_id', '20000000-0000-0000-0000-000000000003', 'message', 'x'));
    raise exception 'FAIL: recorded on behalf without people.view';
  exception when insufficient_privilege then null;
  end;
  delete from public.kudos where id = v_id;
  assert exists (select 1 from public.kudos where id = v_id), 'the receiver does not remove a kudos';
  begin
    perform public.save_kudos_value(null, '{"name": "Speed"}');
    raise exception 'FAIL: a non-admin added a value';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
-- Ada retires Innovation and adds Craft; the name is unique.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb; v_innov uuid := (select id from public.kudos_values where name = 'Innovation');
begin
  r := public.save_kudos_value(v_innov, '{"name": "Innovation", "description": "Found a smarter way.", "active": false}');
  assert (select not active from public.kudos_values where id = v_innov), 'a value retires';
  r := public.save_kudos_value(null, '{"name": " Craft ", "description": "Did it properly."}');
  assert (select name from public.kudos_values where id = (r ->> 'id')::uuid) = 'Craft', 'a value is added trimmed';
  begin
    perform public.save_kudos_value(null, '{"name": "craft"}');
    raise exception 'FAIL: a duplicate value';
  exception when raise_exception then
    if sqlerrm not like '%already exists%' then raise; end if;
  end;
end $$;
reset role;
-- Alex records a kudos from Omar to Pia three days ago, then edits it; the
-- retired value is refused on a new one; the overview counts.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare
  r jsonb; v_id uuid; o jsonb;
  v_innov uuid := (select id from public.kudos_values where name = 'Innovation');
  v_craft uuid := (select id from public.kudos_values where name = 'Craft');
begin
  r := public.record_kudos(jsonb_build_object('from_person_id', '20000000-0000-0000-0000-000000000003',
    'to_person_id', '20000000-0000-0000-0000-000000000021', 'message', ' Smoke: covered my shift ',
    'value_id', v_craft, 'on_date', (current_date - 3)::text));
  v_id := (r ->> 'id')::uuid;
  assert (select date(created_at) from public.kudos where id = v_id) = current_date - 3, 'dated as asked';
  assert (select posted_by from public.kudos where id = v_id) = '20000000-0000-0000-0000-000000000001', 'the recorder is kept';
  assert (select message from public.kudos where id = v_id) = 'Smoke: covered my shift', 'message trimmed';
  begin
    perform public.record_kudos(jsonb_build_object('from_person_id', '20000000-0000-0000-0000-000000000003',
      'to_person_id', '20000000-0000-0000-0000-000000000021', 'message', 'x', 'value_id', v_innov));
    raise exception 'FAIL: a retired value on a new kudos';
  exception when raise_exception then
    if sqlerrm not like '%retired%' then raise; end if;
  end;
  begin
    perform public.record_kudos(jsonb_build_object('from_person_id', '20000000-0000-0000-0000-000000000003',
      'to_person_id', '20000000-0000-0000-0000-000000000021', 'message', 'x', 'on_date', (current_date + 1)::text));
    raise exception 'FAIL: a future kudos';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.record_kudos(jsonb_build_object('from_person_id', '20000000-0000-0000-0000-000000000021',
      'to_person_id', '20000000-0000-0000-0000-000000000021', 'message', 'x'));
    raise exception 'FAIL: a kudos to oneself';
  exception when invalid_parameter_value then null;
  end;
  r := public.update_kudos(v_id, jsonb_build_object('message', 'Smoke: covered my whole shift', 'value_id', '', 'on_date', current_date::text));
  assert (select message from public.kudos where id = v_id) = 'Smoke: covered my whole shift', 'message edited';
  assert (select value_id from public.kudos where id = v_id) is null, 'value cleared';
  assert (select date(created_at) from public.kudos where id = v_id) = current_date, 'moved to today';
  o := public.kudos_overview(null);
  assert (o ->> 'total')::int >= 2, 'the overview lists what Alex manages: ' || (o ->> 'total');
  assert (select count(*) from jsonb_array_elements(o -> 'rows') x where x ->> 'id' = v_id::text and x ->> 'posted_by_name' = 'Alex Director') = 1,
    'the row says who recorded it';
  assert (select (v ->> 'count')::int from jsonb_array_elements(o -> 'values') v where v ->> 'name' = 'Teamwork') >= 1, 'counts per value';
  assert (select count(*) from jsonb_array_elements(o -> 'values') v where v ->> 'name' = 'Innovation' and (v ->> 'active')::boolean = false) = 1,
    'a retired value is listed as such';
  o := public.kudos_overview(to_char(current_date, 'YYYY-MM'));
  assert (select count(*) from jsonb_array_elements(o -> 'rows') x where x ->> 'id' = v_id::text) = 1, 'the month filter keeps this month';
  begin
    perform public.kudos_overview('2026-9');
    raise exception 'FAIL: a bad month';
  exception when invalid_parameter_value then null;
  end;
end $$;
reset role;
-- Bea manages only Company B: none of these rows are hers.
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea
set role authenticated;
do $$
declare o jsonb := public.kudos_overview(null);
begin
  assert (select count(*) from jsonb_array_elements(o -> 'rows') x where x ->> 'message' like 'Smoke:%') = 0, 'Bea sees no Company A kudos';
end $$;
reset role;

-- Bonuses and the net estimate. A person employed in A with no EUR record
-- shows a bonus waiting; Pia's bonus lands in the next EUR period once.
insert into public.people (id, full_name) values ('20000000-0000-0000-0000-000000000044', 'Wilma Waiting');
insert into public.employment_periods (id, person_id, company_id, job_title, status, start_date) values
  ('30000000-0000-0000-0000-000000000044', '20000000-0000-0000-0000-000000000044', '10000000-0000-0000-0000-00000000000a', 'Runner', 'active', '2024-01-01');
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar: no payroll capability
set role authenticated;
do $$
begin
  begin
    perform public.set_payroll_settings('10000000-0000-0000-0000-00000000000a', '{"tax_rate_percent": 10, "deductions_flat": 50}');
    raise exception 'FAIL: settings without payroll.individual';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.add_payroll_item(jsonb_build_object('person_id', '20000000-0000-0000-0000-000000000021',
      'company_id', '10000000-0000-0000-0000-00000000000a', 'amount', 250, 'currency', 'EUR', 'reason', 'x'));
    raise exception 'FAIL: a bonus without payroll.individual';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona (payroll.individual in A)
set role authenticated;
do $$
declare r jsonb; v_id uuid; v_item uuid; v_wait uuid; v_line record;
begin
  assert (public.payroll_settings('10000000-0000-0000-0000-00000000000b') ->> 'own')::boolean = false, 'B has no settings of its own';
  begin
    perform public.set_payroll_settings('10000000-0000-0000-0000-00000000000a', '{"tax_rate_percent": 150, "deductions_flat": 0}');
    raise exception 'FAIL: a rate above 100';
  exception when invalid_parameter_value then null;
  end;
  r := public.set_payroll_settings('10000000-0000-0000-0000-00000000000a', '{"tax_rate_percent": "10", "deductions_flat": "50"}');
  assert (public.payroll_settings('10000000-0000-0000-0000-00000000000a') ->> 'tax_rate_percent')::numeric = 10, 'rate saved';
  assert (public.payroll_settings('10000000-0000-0000-0000-00000000000a') ->> 'own')::boolean, 'A has its own';

  r := public.add_payroll_item(jsonb_build_object('person_id', '20000000-0000-0000-0000-000000000021',
    'company_id', '10000000-0000-0000-0000-00000000000a', 'amount', '250', 'currency', 'eur', 'reason', ' Quarter bonus ',
    'item_date', (current_date + 95)::text));
  v_item := (r ->> 'id')::uuid;
  assert (select currency || '|' || reason from public.payroll_items where id = v_item) = 'EUR|Quarter bonus', 'bonus normalised';
  r := public.add_payroll_item(jsonb_build_object('person_id', '20000000-0000-0000-0000-000000000044',
    'company_id', '10000000-0000-0000-0000-00000000000a', 'amount', 100, 'currency', 'EUR', 'reason', 'Welcome bonus'));
  v_wait := (r ->> 'id')::uuid;
  begin
    perform public.add_payroll_item(jsonb_build_object('person_id', '20000000-0000-0000-0000-000000000021',
      'company_id', '10000000-0000-0000-0000-00000000000a', 'amount', -5, 'currency', 'EUR', 'reason', 'x'));
    raise exception 'FAIL: a negative bonus';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_payroll_item(jsonb_build_object('person_id', '20000000-0000-0000-0000-000000000005',
      'company_id', '10000000-0000-0000-0000-00000000000a', 'amount', 5, 'currency', 'EUR', 'reason', 'x'));
    raise exception 'FAIL: a bonus for someone not employed here';
  exception when invalid_parameter_value then null;
  end;

  -- The next EUR period sweeps Pia's bonus; Wilma's waits (no line).
  r := public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date + 100, current_date + 130, 'EUR', 'with bonuses');
  v_id := (r ->> 'period_id')::uuid;
  assert (r ->> 'bonuses')::int = 1, 'one bonus included: ' || r::text;
  assert (r ->> 'bonuses_waiting')::int = 1, 'one bonus waiting: ' || r::text;
  assert (select period_id from public.payroll_items where id = v_item) = v_id, 'the bonus is attached to the period';
  assert (select period_id from public.payroll_items where id = v_wait) is null, 'the waiting bonus stays pending';
  select * into v_line from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000021';
  assert v_line.amount = 1200 and v_line.bonus = 250 and v_line.gross = 1450, 'gross = amount + bonus: ' || row_to_json(v_line)::text;
  assert v_line.tax = 145.00 and v_line.deductions = 50 and v_line.net = 1255.00, 'net = gross - tax - deductions: ' || row_to_json(v_line)::text;
  assert (select tax_rate_percent from public.payroll_periods where id = v_id) = 10, 'the period snapshots the rate';
  assert (select sum(deductions) from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000001') = 50,
    'the flat deduction once per person';
  assert (select count(*) from public.payroll_lines where period_id = v_id and bonus <> 0) = 1, 'the bonus on one line only';
  begin
    perform public.remove_payroll_item(v_item);
    raise exception 'FAIL: removed a swept bonus';
  exception when raise_exception then
    if sqlerrm not like '%in a prepared period%' then raise; end if;
  end;
  -- Preparing again attaches it once more, not twice.
  r := public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date + 100, current_date + 130, 'EUR', null);
  assert (r ->> 'bonuses')::int = 1, 'prepared again: still one bonus';
  assert (select sum(bonus) from public.payroll_lines where period_id = v_id) = 250, 'still 250 in the lines';
  perform public.remove_payroll_item(v_wait);
  assert not exists (select 1 from public.payroll_items where id = v_wait), 'a pending bonus is removed';
end $$;
reset role;
-- Alex approves, reopens (the bonus goes back to pending), cannot approve
-- again until Fiona prepares again.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare r jsonb;
  v_id uuid := (select id from public.payroll_periods where company_id = '10000000-0000-0000-0000-00000000000a' and period_start = current_date + 100 and currency = 'EUR');
begin
  perform public.approve_payroll_period(v_id);
  r := public.reopen_payroll_period(v_id);
  assert (r ->> 'bonuses_released')::int = 1, 'reopening releases the bonus';
  assert (select period_id from public.payroll_items where reason = 'Quarter bonus') is null, 'the bonus is pending again';
  assert (select reopened_at from public.payroll_periods where id = v_id) is not null, 'reopened_at stamped';
  -- Reviewed: the lines drop the released bonus, at the period's own rate.
  assert (select bonus || '|' || gross || '|' || tax || '|' || net from public.payroll_lines where period_id = v_id and person_id = '20000000-0000-0000-0000-000000000021')
    = '0.00|1200.00|120.00|1030.00', 'the lines no longer carry the released bonus';
  begin
    perform public.approve_payroll_period(v_id);
    raise exception 'FAIL: approved a reopened period without preparing it again';
  exception when raise_exception then
    if sqlerrm not like '%prepare it again%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000002';  -- Fiona
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.prepare_payroll_period('10000000-0000-0000-0000-00000000000a', current_date + 100, current_date + 130, 'EUR', null);
  assert (r ->> 'bonuses')::int = 1, 'prepared again after reopening: the bonus is back in';
  assert (select reopened_at from public.payroll_periods where id = (r ->> 'period_id')::uuid) is null, 'reopened_at cleared';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare v_id uuid := (select id from public.payroll_periods where company_id = '10000000-0000-0000-0000-00000000000a' and period_start = current_date + 100 and currency = 'EUR');
begin
  perform public.approve_payroll_period(v_id);
  assert (select status from public.payroll_periods where id = v_id) = 'approved', 'approved after preparing again';
end $$;
reset role;
-- Omar reads no bonuses; amounts stay out of the audit trail.
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
begin
  assert (select count(*) from public.payroll_items) = 0, 'Omar sees no bonuses';
end $$;
reset role;
do $$
begin
  assert not exists (select 1 from public.activity_log where entity_type = 'payroll_items' and coalesce(after, '{}') ? 'amount'),
    'bonus amounts are not in the audit trail';
  assert not exists (select 1 from public.activity_log where entity_type = 'payroll_lines'
                     and (coalesce(after, '{}') ?| array['gross', 'net', 'tax', 'bonus'] or coalesce(before, '{}') ?| array['gross', 'net', 'tax', 'bonus'])),
    'line estimates are not in the audit trail';
end $$;
set app.test_uid = '';

-- ================================================================ 0067
-- The talent pool: the candidate is a holding-wide record behind
-- candidates.source, every door dedupes without merging, the contact rule is
-- enforced by the database, the CV lives on the candidate, and the Zoho
-- Recruit export comes in through the same door a LinkedIn export will use.
-- Fixtures: P1 (a Zoho row, mixed-case email on purpose), P2 (never), P3
-- (later), P4 (later, but the date has passed), P5 (four applications in B,
-- for the count beside the capped list), jobs JB and JB2-4 in B, Zed Hired
-- employed in A, and Omar with ONLY candidates.source in A — a sourcer with
-- no candidates.view anywhere, the sharpest proof that the pool opens no
-- company history.
insert into public.candidates (id, full_name, email, phone, provider, provider_ref, linkedin_url) values
  ('80000000-0000-0000-0000-000000000671', 'Pool Person', 'Pool@Example.test', '+389 70 000 067',
   'zoho_recruit', 'Z-1', 'https://www.linkedin.com/in/pool-person/');
insert into public.candidates (id, full_name, do_not_contact, do_not_contact_reason, do_not_contact_at) values
  ('80000000-0000-0000-0000-000000000672', 'Never Person', true, 'Asked us to stop.', now());
insert into public.candidates (id, full_name, contact_later, contact_again_after) values
  ('80000000-0000-0000-0000-000000000673', 'Later Person', true, current_date + 30),
  ('80000000-0000-0000-0000-000000000674', 'Expired Person', true, current_date - 1);
insert into public.candidates (id, full_name) values
  ('80000000-0000-0000-0000-000000000675', 'Busy Person');
insert into public.jobs (id, company_id, title, status) values
  ('70000000-0000-0000-0000-000000000067', '10000000-0000-0000-0000-00000000000b', 'Pool Role B', 'open'),
  ('70000000-0000-0000-0000-000000000068', '10000000-0000-0000-0000-00000000000b', 'Pool Role B2', 'open'),
  ('70000000-0000-0000-0000-000000000069', '10000000-0000-0000-0000-00000000000b', 'Pool Role B3', 'open'),
  ('70000000-0000-0000-0000-00000000006a', '10000000-0000-0000-0000-00000000000b', 'Pool Role B4', 'open');
insert into public.applications (id, job_id, company_id, candidate_id) values
  ('90000000-0000-0000-0000-000000000675', '70000000-0000-0000-0000-000000000067', '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-000000000675'),
  ('90000000-0000-0000-0000-000000000676', '70000000-0000-0000-0000-000000000068', '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-000000000675'),
  ('90000000-0000-0000-0000-000000000677', '70000000-0000-0000-0000-000000000069', '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-000000000675'),
  ('90000000-0000-0000-0000-000000000678', '70000000-0000-0000-0000-00000000006a', '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-000000000675');
insert into public.people (id, full_name, personal_email) values
  ('20000000-0000-0000-0000-000000000067', 'Zed Hired', 'zed@example.test');
insert into public.employment_periods (id, person_id, company_id, job_title, status, start_date) values
  ('30000000-0000-0000-0000-000000000067', '20000000-0000-0000-0000-000000000067',
   '10000000-0000-0000-0000-00000000000a', 'Engineer', 'active', current_date - 100);
create temp table omar_added as
  select g.id as grant_id, v.cap as capability_key
  from public.access_grants g, (values ('candidates.source')) v(cap)
  where g.person_id = '20000000-0000-0000-0000-000000000003'
    and g.company_id = '10000000-0000-0000-0000-00000000000a'
    and not exists (select 1 from public.grant_capabilities gc where gc.grant_id = g.id and gc.capability_key = v.cap);
insert into public.grant_capabilities (grant_id, capability_key) select grant_id, capability_key from omar_added;

-- 1. Seeds, helpers, the backfill shape.
do $$
begin
  assert (select label from public.capabilities where key = 'candidates.source') = 'Work the talent pool (holding-wide)',
    'the pool capability is seeded';
  assert exists (select 1 from public.capability_dependencies
                 where capability_key = 'candidates.source' and requires_key = 'candidates.view'),
    'the pool needs candidates.view';
  assert (select string_agg(p.name, ',' order by p.name) from public.preset_capabilities pc
          join public.permission_presets p on p.id = pc.preset_id
          where pc.capability_key = 'candidates.source' and p.company_id is null) = 'Holding HR,Recruiter',
    'Holding HR and Recruiter carry the pool; Company HR and Hiring Manager do not';
  assert (select string_agg(key || '=' || label, ';' order by sort_order) from public.candidate_sources)
    = 'head_hunt=Head hunt;linkedin_profile=LinkedIn profile capture;linkedin_ad=LinkedIn advertisement;'
      'careers_page=Company careers page;job_board=Job board or advertisement;referral=Referral;'
      'added_by_hand=Added by hand;imported=Imported, source unknown',
    'eight sources with their labels';
  assert (select label from public.candidate_sources where key = 'careers_page')
         = (select label from public.channels where key = 'careers'),
    'careers_page equals the careers channel label';
  assert exists (select 1 from pg_indexes where indexname = 'applications_candidate_idx'),
    'applications (candidate_id) is indexed';
  assert (select provider || '|' || source_key from public.candidates where id = '80000000-0000-0000-0000-000000000001')
         = 'manual|added_by_hand', 'Cathy is a manual, hand-added record';
  assert app.phone_key('077597288') = '77597288' and app.phone_key('+389 70 813 118') = '70813118'
     and app.phone_key('0038978316858') = '78316858' and app.phone_key('12345') is null, 'phone keys';
  assert app.name_key('Dimitar (Benjamin) Iliev') = 'dimitar iliev' and app.name_key('Iliev Dimitar') = 'dimitar iliev'
     and app.name_key('Fredrik Möllersten') = 'fredrik mollersten', 'name keys';
  assert app.name_key('Петар Петров') = 'петар петров', 'Cyrillic stays Cyrillic';
  assert app.linkedin_key('https://www.linkedin.com/in/John-Doe/?trk=x') = 'john-doe'
     and app.linkedin_key('https://example.com/in/x') is null, 'linkedin keys';
  assert app.mask_email('pool@example.test') = 'p***@example.test' and app.mask_email('nope') is null, 'masked email';
  assert (select phone_key || '|' || name_key || '|' || linkedin_key from public.candidates
          where id = '80000000-0000-0000-0000-000000000671') = '70000067|person pool|pool-person',
    'P1 keys are generated';
end $$;

-- 2. Alex (candidates.review in A, no pool): the 0006 fallback is gone and
-- a candidate is born only through the RPC.
set app.test_uid = '00000000-0000-0000-0000-000000000001';
set role authenticated;
do $$
begin
  assert exists (select 1 from public.candidates where id = '80000000-0000-0000-0000-000000000001'),
    'Alex sees Cathy through her A application';
  assert not exists (select 1 from public.candidates where id in
    ('80000000-0000-0000-0000-000000000671', '80000000-0000-0000-0000-000000000672',
     '80000000-0000-0000-0000-000000000673', '80000000-0000-0000-0000-000000000674')),
    'application-less candidates are invisible to a reviewer';
  begin
    insert into public.candidates (full_name) values ('Direct Insert');
    raise exception 'FAIL: a reviewer inserted a candidate directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.upsert_sourced_candidate('manual', null, '{"full_name":"No Job"}');
    raise exception 'FAIL: added to the pool without the capability';
  exception when insufficient_privilege then
    if sqlerrm not like '%Adding to the talent pool needs the "Work the talent pool" capability.%' then raise; end if;
  end;
  begin
    perform public.upsert_sourced_candidate('linkedin_recruiter', 'LR-0', '{"full_name":"Prov Rec"}');
    raise exception 'FAIL: imported a provider record without the capability';
  exception when insufficient_privilege then
    if sqlerrm not like '%Importing provider records needs the "Work the talent pool" capability.%' then raise; end if;
  end;
end $$;

-- 3. Alex adds to job A: a match is offered without exposing the record and
-- nothing is written; attaching needs a real identity match.
do $$
declare r jsonb; n int;
begin
  select count(*) into n from public.candidates;
  r := public.upsert_sourced_candidate('manual', null, jsonb_build_object(
    'full_name', 'Pool Person', 'email', 'pool@example.test', 'job_id', '70000000-0000-0000-0000-000000000001'));
  assert r->>'action' = 'matches' and jsonb_array_length(r->'matches') = 1, 'one match offered: ' || r::text;
  assert r->'matches'->0->>'match' = 'email' and not (r->'matches'->0->>'visible')::boolean
     and (r->'matches'->0->>'attachable')::boolean, 'an email match is attachable but not visible: ' || r::text;
  assert r->'matches'->0->>'email' = 'p***@example.test' and r->'matches'->0->>'phone' is null
     and r->'matches'->0->'applications' = '[]'::jsonb and r->'matches'->0->>'last_activity_at' is null,
    'masked email, no phone, no history: ' || r::text;
  assert (select count(*) from public.candidates) = n, 'nothing is written on a match';
  r := public.upsert_sourced_candidate('manual', null, jsonb_build_object(
    'full_name', 'Person Pool', 'job_id', '70000000-0000-0000-0000-000000000001'));
  assert r->>'action' = 'matches' and r->'matches'->0->>'match' = 'name'
     and not (r->'matches'->0->>'attachable')::boolean, 'a name match is a suggestion, not attachable: ' || r::text;
  -- A name-only match cannot be acted on, so it carries no contact rule.
  r := public.upsert_sourced_candidate('manual', null, jsonb_build_object(
    'full_name', 'Person Never', 'job_id', '70000000-0000-0000-0000-000000000001'));
  assert r->>'action' = 'matches' and r->'matches'->0->>'match' = 'name'
     and not (r->'matches'->0->>'attachable')::boolean and not (r->'matches'->0->>'do_not_contact')::boolean,
    'a name-only match does not disclose never: ' || r::text;
  r := public.upsert_sourced_candidate('manual', null, jsonb_build_object(
    'full_name', 'Person Later', 'job_id', '70000000-0000-0000-0000-000000000001'));
  assert r->>'action' = 'matches' and r->'matches'->0->>'match' = 'name'
     and not (r->'matches'->0->>'contact_later')::boolean and r->'matches'->0->>'contact_again_after' is null,
    'a name-only match does not disclose contact later: ' || r::text;
  assert (select count(*) from public.candidates) = n, 'nothing is written on a name match';
  begin
    perform public.upsert_sourced_candidate('manual', null, jsonb_build_object(
      'full_name', 'Person Pool', 'attach_to', '80000000-0000-0000-0000-000000000671',
      'job_id', '70000000-0000-0000-0000-000000000001'));
    raise exception 'FAIL: attached on a name alone';
  exception when insufficient_privilege then
    if sqlerrm not like '%You cannot attach to that candidate.%' then raise; end if;
  end;
  r := public.upsert_sourced_candidate('manual', null, jsonb_build_object(
    'full_name', 'Person Pool', 'email', 'pool@example.test', 'attach_to', '80000000-0000-0000-0000-000000000671',
    'job_id', '70000000-0000-0000-0000-000000000001'));
  assert r->>'action' = 'attached' and r->>'id' = '80000000-0000-0000-0000-000000000671'
     and r->>'application_id' is not null, 'attached by email: ' || r::text;
  assert (select stage_key || '|' || source_key || '|' || company_id from public.applications
          where id = (r->>'application_id')::uuid) = 'new|added_by_hand|10000000-0000-0000-0000-00000000000a',
    'an A application at new, added by hand';
  assert exists (select 1 from public.candidates where id = '80000000-0000-0000-0000-000000000671'), 'P1 is visible to Alex now';
  assert (select count(*) from public.applications where candidate_id = '80000000-0000-0000-0000-000000000671') = 1,
    'one application for P1';
  begin
    perform public.upsert_sourced_candidate('manual', null, jsonb_build_object(
      'full_name', 'Person Pool', 'email', 'pool@example.test', 'attach_to', '80000000-0000-0000-0000-000000000671',
      'job_id', '70000000-0000-0000-0000-000000000001'));
    raise exception 'FAIL: a second open application for the same job';
  exception when raise_exception then
    if sqlerrm not like '%already has an open application for this job.%' then raise; end if;
  end;
  r := public.upsert_sourced_candidate('manual', null, jsonb_build_object(
    'full_name', 'Person Pool', 'email', 'other@example.test', 'ignore_matches', true,
    'job_id', '70000000-0000-0000-0000-000000000001'));
  assert r->>'action' = 'created' and r->>'application_id' is not null, 'ignoring the matches creates: ' || r::text;
  assert (select sourced_by::text || '|' || provider || '|' || source_key from public.candidates where id = (r->>'id')::uuid)
         = '20000000-0000-0000-0000-000000000001|manual|added_by_hand', 'sourced by Alex, manual';
end $$;
reset role;
-- A superuser insert with app.test_uid still set (the 0039 fixture shape):
-- the contact guard lets Cathy through and the touch passes the field guard.
insert into public.applications (id, job_id, company_id, candidate_id) values
  ('90000000-0000-0000-0000-000000000067', '70000000-0000-0000-0000-000000000067',
   '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-000000000001');

-- 4. Alex edits identity where the candidate applied; provenance, the
-- contact rule and the pool fields are locked; only admins delete.
set role authenticated;
do $$
declare n int;
begin
  update public.candidates set phone = '+389 70 000 068' where id = '80000000-0000-0000-0000-000000000671';
  get diagnostics n = row_count;
  assert n = 1, 'a reviewer edits identity fields where the candidate applied';
  assert (select phone_key from public.candidates where id = '80000000-0000-0000-0000-000000000671') = '70000068',
    'the phone key follows the phone';
  begin
    update public.candidates set source_key = 'head_hunt' where id = '80000000-0000-0000-0000-000000000671';
    raise exception 'FAIL: a reviewer changed the source';
  exception when insufficient_privilege then
    if sqlerrm not like '%Changing talent-pool fields needs the "Work the talent pool" capability.%' then raise; end if;
  end;
  begin
    update public.candidates set do_not_contact = true, do_not_contact_reason = 'x'
      where id = '80000000-0000-0000-0000-000000000671';
    raise exception 'FAIL: a reviewer changed the contact rule';
  exception when insufficient_privilege then
    if sqlerrm not like '%Change the contact rule from the candidate''s record.%' then raise; end if;
  end;
  begin
    update public.candidates set provider_ref = 'Z-9' where id = '80000000-0000-0000-0000-000000000671';
    raise exception 'FAIL: a reviewer changed the provenance';
  exception when insufficient_privilege then
    if sqlerrm not like '%Where a candidate came from is not editable.%' then raise; end if;
  end;
  delete from public.candidates where id = '80000000-0000-0000-0000-000000000671';
  get diagnostics n = row_count;
  assert n = 0, 'only admins delete a candidate';
  -- The contact-rule check is not callable by hand: it would tell anyone who
  -- knows a uuid the name, the archived state and the rule of a candidate
  -- they cannot see. Only the trigger and the RPCs (definer, postgres) call it.
  begin
    perform app.assert_contactable('80000000-0000-0000-0000-000000000672', false);
    raise exception 'FAIL: a reviewer called assert_contactable directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- 5. Bea (Company HR in B): the pool opens nothing; the wall holds for a
-- direct insert, without the reason she may not see.
set app.test_uid = '00000000-0000-0000-0000-000000000005';
set role authenticated;
do $$
begin
  begin
    perform public.add_candidate_to_job('80000000-0000-0000-0000-000000000671', '70000000-0000-0000-0000-000000000067');
    raise exception 'FAIL: Bea added a candidate she cannot see';
  exception when insufficient_privilege then
    if sqlerrm not like '%You cannot see that candidate.%' then raise; end if;
  end;
  begin
    insert into public.applications (job_id, company_id, candidate_id) values
      ('70000000-0000-0000-0000-000000000067', '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-000000000672');
    raise exception 'FAIL: a direct insert bypassed the contact rule';
  exception when raise_exception then
    if sqlerrm not like '%Never Person asked not to be contacted again.%' or sqlerrm like '%Asked us to stop%' then raise; end if;
  end;
  begin
    perform public.add_candidate_to_job('80000000-0000-0000-0000-000000000671', '70000000-0000-0000-0000-000000000001');
    raise exception 'FAIL: Bea added to a Company A job';
  exception when insufficient_privilege then
    if sqlerrm not like '%"Record interview feedback" capability in Company A.%' then raise; end if;
  end;
end $$;
reset role;

-- 6. Omar (candidates.source only): the whole pool, none of the history.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare r jsonb;
begin
  assert (select count(*) from public.candidates where id in
    ('80000000-0000-0000-0000-000000000671', '80000000-0000-0000-0000-000000000672', '80000000-0000-0000-0000-000000000673')) = 3,
    'a sourcer sees the whole pool';
  assert (select count(*) from public.applications) = 0, 'and no company history';
  r := public.search_candidates('{"q":"pool"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = '80000000-0000-0000-0000-000000000671'),
    'search by name: ' || r::text;
  r := public.search_candidates('{"q":"070 000 068"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = '80000000-0000-0000-0000-000000000671'),
    'search by phone: ' || r::text;
  r := public.search_candidates('{"contact":"ok"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = '80000000-0000-0000-0000-000000000671')
     and exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = '80000000-0000-0000-0000-000000000674')
     and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' in
       ('80000000-0000-0000-0000-000000000672', '80000000-0000-0000-0000-000000000673')),
    'the ok filter: an expired contact-later date is contactable again: ' || r::text;
  r := public.search_candidates('{"contact":"do_not_contact"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = '80000000-0000-0000-0000-000000000672')
     and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' in
       ('80000000-0000-0000-0000-000000000671', '80000000-0000-0000-0000-000000000673')),
    'the never filter: ' || r::text;
  r := public.search_candidates('{"contact":"wait"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = '80000000-0000-0000-0000-000000000673')
     and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' in
       ('80000000-0000-0000-0000-000000000671', '80000000-0000-0000-0000-000000000672', '80000000-0000-0000-0000-000000000674')),
    'the wait filter: a passed date is no longer a wait: ' || r::text;
  r := public.search_candidates('{"activity":"90d"}');
  assert (select count(*) from jsonb_array_elements(r->'rows') x where x->>'id' in
    ('80000000-0000-0000-0000-000000000671', '80000000-0000-0000-0000-000000000672', '80000000-0000-0000-0000-000000000673')) = 3,
    'recent activity: all three: ' || r::text;
  r := public.search_candidates('{"company_id":"10000000-0000-0000-0000-00000000000a"}');
  assert (r->>'total')::int = 0, 'a company filter needs candidates.view there: ' || r::text;
  r := public.search_candidates('{}');
  assert (r->>'total')::int >= 3 and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->'applications' <> '[]'::jsonb)
     and not exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'applications_count')::int <> 0),
    'every row shows no applications, and a zero count, to a sourcer without candidates.view: ' || r::text;
  begin
    perform public.add_candidate_to_job('80000000-0000-0000-0000-000000000671', '70000000-0000-0000-0000-000000000001');
    raise exception 'FAIL: a sourcer added to a job without review there';
  exception when insufficient_privilege then
    if sqlerrm not like '%"Record interview feedback" capability in Company A.%' then raise; end if;
  end;
end $$;
reset role;
-- Ada (admin, candidates.view everywhere): the count is every visible
-- application, the embedded list stays capped at three.
set app.test_uid = '00000000-0000-0000-0000-000000000004';
set role authenticated;
do $$
declare r jsonb; x jsonb;
begin
  r := public.search_candidates('{"q":"busy"}');
  select v into x from jsonb_array_elements(r->'rows') v where v->>'id' = '80000000-0000-0000-0000-000000000675';
  assert x is not null and (x->>'applications_count')::int = 4 and jsonb_array_length(x->'applications') = 3,
    'four visible applications counted beside a list of three: ' || r::text;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea
set role authenticated;
do $$
begin
  begin
    perform public.search_candidates('{}');
    raise exception 'FAIL: Bea searched the pool';
  exception when insufficient_privilege then
    if sqlerrm not like '%The talent pool needs the "Work the talent pool" capability.%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
begin
  begin
    perform public.search_candidates('{}');
    raise exception 'FAIL: Alex searched the pool';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- 7. Omar sources: a manual record, a provider-keyed record created then
-- updated in place, a possible duplicate reported and never merged.
set app.test_uid = '00000000-0000-0000-0000-000000000003';
set role authenticated;
do $$
declare r jsonb; v_lr uuid;
begin
  r := public.upsert_sourced_candidate('manual', null,
    '{"full_name":"New Pool","email":"newpool@example.test","source_key":"head_hunt"}');
  assert r->>'action' = 'created', 'created: ' || r::text;
  assert (select sourced_by::text || '|' || coalesce(provider_ref, 'null') || '|' || source_key from public.candidates
          where id = (r->>'id')::uuid) = '20000000-0000-0000-0000-000000000003|null|head_hunt',
    'sourced by Omar, no provider reference';
  -- A pool holder sees the match, so it is attachable and the rule is disclosed.
  r := public.upsert_sourced_candidate('manual', null, '{"full_name":"Person Never"}');
  assert r->>'action' = 'matches' and r->'matches'->0->>'match' = 'name'
     and (r->'matches'->0->>'attachable')::boolean and (r->'matches'->0->>'do_not_contact')::boolean,
    'an attachable match discloses never: ' || r::text;
  r := public.upsert_sourced_candidate('linkedin_recruiter', 'LR-1',
    '{"full_name":"Lin Ked","current_title":"Dev","created_at":"2024-03-01T00:00:00Z"}');
  assert r->>'action' = 'created', 'a provider record is created: ' || r::text;
  v_lr := (r->>'id')::uuid;
  assert (select created_at from public.candidates where id = v_lr) = '2024-03-01T00:00:00Z'::timestamptz
     and (select last_activity_at = created_at from public.candidates where id = v_lr),
    'created_at honoured, activity starts there';
  r := public.upsert_sourced_candidate('linkedin_recruiter', 'LR-1',
    '{"full_name":"Lin Ked","current_title":"Senior Dev","created_at":"2024-03-01T00:00:00Z"}');
  assert r->>'action' = 'updated' and (r->>'id')::uuid = v_lr, 'the same ref updates in place: ' || r::text;
  assert (select current_title from public.candidates where id = v_lr) = 'Senior Dev', 'the title changed';
  assert (select created_at from public.candidates where id = v_lr) = '2024-03-01T00:00:00Z'::timestamptz, 'created_at unchanged';
  -- A JSON-null custom is "no custom": stored as {}, and merged into an
  -- existing record it never turns custom into an array.
  r := public.upsert_sourced_candidate('linkedin_recruiter', 'LR-1', '{"full_name":"Lin Ked","custom":null}');
  assert r->>'action' = 'updated'
     and (select custom from public.candidates where id = v_lr) = '{}'::jsonb, 'null custom merges to an object: ' || r::text;
  r := public.upsert_sourced_candidate('manual', null,
    '{"full_name":"Null Custom","email":"nullcustom@example.test","ignore_matches":true,"custom":null}');
  assert r->>'action' = 'created'
     and (select custom from public.candidates where id = (r->>'id')::uuid) = '{}'::jsonb, 'null custom is stored as {}: ' || r::text;
  r := public.upsert_sourced_candidate('linkedin_recruiter', 'LR-2', '{"full_name":"Lin Kedd","email":"newpool@example.test"}');
  assert r->>'action' = 'created' and exists (select 1 from jsonb_array_elements(r->'possible_duplicates') d
    where d->>'full_name' = 'New Pool' and d->>'match' = 'email'), 'possible duplicates name the first: ' || r::text;
  begin
    perform public.upsert_sourced_candidate('manual', 'X-1', '{"full_name":"Man Ref"}');
    raise exception 'FAIL: a manual record with a reference';
  exception when invalid_parameter_value then
    if sqlerrm not like '%Manual records carry no provider reference.%' then raise; end if;
  end;
  begin
    perform public.upsert_sourced_candidate('manual', null, '{"full_name":"X"}');
    raise exception 'FAIL: a one-letter name';
  exception when invalid_parameter_value then
    if sqlerrm not like '%Enter the candidate''s full name (2 to 200 characters).%' then raise; end if;
  end;
  begin
    perform public.upsert_sourced_candidate('manual', null, '{"full_name":"Nope Source","source_key":"nope"}');
    raise exception 'FAIL: an unknown source';
  exception when invalid_parameter_value then
    if sqlerrm not like '%Unknown candidate source "nope".%' then raise; end if;
  end;
end $$;
reset role;

-- 8. The contact rule on the record, enforced at every door.
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
declare r jsonb;
begin
  begin
    perform public.set_contact_rule('80000000-0000-0000-0000-000000000671', '{"rule":"never"}');
    raise exception 'FAIL: never without a reason';
  exception when invalid_parameter_value then
    if sqlerrm not like '%Say why this person must not be contacted again.%' then raise; end if;
  end;
  r := public.set_contact_rule('80000000-0000-0000-0000-000000000671', '{"rule":"never","reason":"Asked us to stop"}');
  assert (r->>'do_not_contact')::boolean and r->>'do_not_contact_by' = '20000000-0000-0000-0000-000000000003'
     and r->>'do_not_contact_at' is not null, 'never: ' || r::text;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
begin
  begin
    perform public.add_candidate_to_job('80000000-0000-0000-0000-000000000671', '70000000-0000-0000-0000-000000000067');
    raise exception 'FAIL: added a never-contact candidate';
  exception when raise_exception then
    if sqlerrm not like '%Pool Person asked not to be contacted again: Asked us to stop%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.set_contact_rule('80000000-0000-0000-0000-000000000671',
    jsonb_build_object('rule', 'later', 'contact_again_after', (current_date + 10)::text));
  assert not (r->>'do_not_contact')::boolean and r->>'do_not_contact_reason' is null and (r->>'contact_later')::boolean
     and (r->>'contact_again_after')::date = current_date + 10, 'later clears never: ' || r::text;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb;
begin
  begin
    perform public.add_candidate_to_job('80000000-0000-0000-0000-000000000673', '70000000-0000-0000-0000-000000000001');
    raise exception 'FAIL: added a contact-later candidate without overriding';
  exception when raise_exception then
    if sqlerrm not like '%Later Person asked to be contacted after%' then raise; end if;
  end;
  r := public.add_candidate_to_job('80000000-0000-0000-0000-000000000673', '70000000-0000-0000-0000-000000000001',
                                   p_override_wait => true);
  assert (select stage_key || '|' || source_key || '|' || company_id from public.applications
          where id = (r->>'application_id')::uuid) = 'new|head_hunt|10000000-0000-0000-0000-00000000000a',
    'overridden: an A application at new, head hunt';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.set_contact_rule('80000000-0000-0000-0000-000000000671', '{"rule":"ok"}');
  assert not (r->>'do_not_contact')::boolean and not (r->>'contact_later')::boolean
     and r->>'contact_again_after' is null and r->>'do_not_contact_reason' is null and r->>'do_not_contact_by' is null,
    'ok clears everything: ' || r::text;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
begin
  begin
    perform public.set_contact_rule('80000000-0000-0000-0000-000000000671', '{"rule":"ok"}');
    raise exception 'FAIL: a reviewer changed the contact rule through the RPC';
  exception when insufficient_privilege then
    if sqlerrm not like '%Changing the contact rule needs the "Work the talent pool" capability.%' then raise; end if;
  end;
end $$;
reset role;

-- 9. Files on the candidate, objects at candidate/{id}/…, beside the 0013 shape.
set app.test_uid = '00000000-0000-0000-0000-000000000003';  -- Omar
set role authenticated;
do $$
begin
  insert into public.candidate_files (candidate_id, kind, storage_path, original_name, mime_type, size_bytes, uploaded_by)
    values ('80000000-0000-0000-0000-000000000672', 'cv', 'candidate/80000000-0000-0000-0000-000000000672/g.pdf',
            'g.pdf', 'application/pdf', 10, '20000000-0000-0000-0000-000000000003');
  insert into storage.objects (bucket_id, name) values
    ('candidate-files', 'candidate/80000000-0000-0000-0000-000000000672/g.pdf');
  insert into public.candidate_files (candidate_id, kind, storage_path, original_name, mime_type, size_bytes, uploaded_by)
    values ('80000000-0000-0000-0000-000000000671', 'cv', 'candidate/80000000-0000-0000-0000-000000000671/h.pdf',
            'h.pdf', 'application/pdf', 10, '20000000-0000-0000-0000-000000000003');
  insert into storage.objects (bucket_id, name) values
    ('candidate-files', 'candidate/80000000-0000-0000-0000-000000000671/h.pdf');
  begin
    insert into public.candidate_files (candidate_id, kind, storage_path, original_name, mime_type, size_bytes, provider)
      values ('80000000-0000-0000-0000-000000000672', 'cv', 'candidate/80000000-0000-0000-0000-000000000672/z.pdf',
              'z.pdf', 'application/pdf', 10, 'zoho_recruit');
    raise exception 'FAIL: an imported-shaped row from the app';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.candidate_files (candidate_id, kind, storage_path, original_name, mime_type, size_bytes)
      values ('80000000-0000-0000-0000-000000000672', 'cv', 'candidate/80000000-0000-0000-0000-000000000673/x.pdf',
              'x.pdf', 'application/pdf', 10);
    raise exception 'FAIL: a path under another candidate';
  exception when check_violation then null;
  end;
  begin
    insert into storage.objects (bucket_id, name) values ('candidate-files', 'candidate/not-a-uuid/x.pdf');
    raise exception 'FAIL: a malformed pool path was writable by a sourcer';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
begin
  assert (select count(*) from storage.objects where bucket_id = 'candidate-files'
          and name like 'candidate/80000000-0000-0000-0000-000000000671/%') = 1, 'Alex reads P1 objects (P1 applied to A)';
  assert (select count(*) from storage.objects where bucket_id = 'candidate-files'
          and name like 'candidate/80000000-0000-0000-0000-000000000672/%') = 0, 'and none of P2';
  assert (select count(*) from public.candidate_files where candidate_id = '80000000-0000-0000-0000-000000000671') = 1
     and (select count(*) from public.candidate_files where candidate_id = '80000000-0000-0000-0000-000000000672') = 0,
    'the rows follow the same rule';
  begin
    insert into storage.objects (bucket_id, name) values ('candidate-files', 'candidate/not-a-uuid/x.pdf');
    raise exception 'FAIL: a malformed pool path was writable by a reviewer';
  exception when insufficient_privilege then null;
  end;
  insert into storage.objects (bucket_id, name) values ('candidate-files', '90000000-0000-0000-0000-000000000001/f67.pdf');
  assert (select public from storage.buckets where id = 'candidate-files') = false, 'the bucket is still private';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea
set role authenticated;
do $$
begin
  assert (select count(*) from storage.objects where bucket_id = 'candidate-files' and name like 'candidate/%') = 0,
    'Bea reads no pool objects';
  assert (select count(*) from public.candidate_files) = 0, 'nor pool file rows';
end $$;
reset role;
set app.test_uid = '';

-- 10. Activity moves forward only; the audit trail is redacted and silent on the touch.
do $$
declare v_app uuid; v_before timestamptz; n int;
begin
  select id into v_app from public.applications
    where candidate_id = '80000000-0000-0000-0000-000000000671' and job_id = '70000000-0000-0000-0000-000000000001';
  assert (select last_activity_at from public.candidates where id = '80000000-0000-0000-0000-000000000671')
         >= (select received_at from public.applications where id = v_app), 'the application touched the candidate';
  select last_activity_at into v_before from public.candidates where id = '80000000-0000-0000-0000-000000000671';
  insert into public.application_events (application_id, kind, body, created_at) values (v_app, 'note', 'Old note', '2023-01-01');
  assert (select last_activity_at from public.candidates where id = '80000000-0000-0000-0000-000000000671') = v_before,
    'an old event never moves activity backwards';
  assert not exists (select 1 from public.activity_log where entity_type = 'candidates'
                     and entity_id = '80000000-0000-0000-0000-000000000671' and company_id is not null),
    'candidate audit rows carry no company';
  assert exists (select 1 from public.activity_log where entity_type = 'candidates'
                 and entity_id = '80000000-0000-0000-0000-000000000671' and after ? 'do_not_contact'),
    'the contact flag is in the trail';
  assert not exists (select 1 from public.activity_log where entity_type = 'candidates'
                     and entity_id = '80000000-0000-0000-0000-000000000671'
                     and (coalesce(after, '{}') ?| array['email', 'phone', 'custom'] or coalesce(before, '{}') ?| array['email', 'phone', 'custom'])),
    'email, phone and custom are redacted';
  select count(*) into n from public.activity_log where entity_type = 'candidates' and entity_id = '80000000-0000-0000-0000-000000000671';
  assert n = 5, 'the fixture insert, the phone edit and three contact-rule writes are audited, nothing from the touch: ' || n;
end $$;

-- 11. The report attributes by source label.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
declare r jsonb;
begin
  r := public.recruitment_report('10000000-0000-0000-0000-00000000000a', current_date - 1, current_date + 1);
  assert exists (select 1 from jsonb_array_elements(r->'sources') s where s->>'source' = 'Added by hand'),
    'the attached application counts as added by hand: ' || (r->'sources')::text;
  assert exists (select 1 from jsonb_array_elements(r->'sources') s where s->>'source' = 'Head hunt'),
    'the override application counts as head hunt: ' || (r->'sources')::text;
end $$;
reset role;
set app.test_uid = '';

-- 12. The Zoho Recruit import: dry run, commit, idempotent re-run, refusal.
do $$
begin
  perform set_config('app.zoho_payload', jsonb_build_object(
    'exported_at', '2026-09-21T00:00:00Z', 'timezone_assumed', 'Europe/Skopje',
    'users', jsonb_build_array(
      jsonb_build_object('zoho_id', 'U-1', 'email', 'alex@a.test', 'name', 'Alex Director'),
      jsonb_build_object('zoho_id', 'U-2', 'email', 'nobody@zoho.test', 'name', 'Nobody Zoho')),
    'jobs', jsonb_build_array(
      jsonb_build_object('zoho_id', 'ZJ-1', 'display_id', 'ZR_1_JOB', 'company_code', 'A', 'title', 'Zoho Filled Role',
        'description', 'Filled long ago', 'status', 'filled', 'created_at', '2024-01-10T09:00:00Z',
        'modified_at', '2024-03-01T09:00:00Z', 'date_closed', '2024-03-01T00:00:00Z',
        'custom', jsonb_build_object('zoho', jsonb_build_object('department', 'HUT 4'))),
      jsonb_build_object('zoho_id', 'ZJ-2', 'display_id', 'ZR_2_JOB', 'company_code', 'A', 'title', 'Zoho Open Role',
        'status', 'open', 'created_at', '2024-04-01T09:00:00Z', 'modified_at', '2024-05-01T09:00:00Z',
        'custom', null),   -- a JSON null: the re-run must still find custom.zoho.id
      jsonb_build_object('zoho_id', 'ZJ-3', 'display_id', 'ZR_3_JOB', 'company_code', 'A', 'title', 'Zoho Cancelled Role',
        'status', 'closed', 'created_at', '2024-01-05T09:00:00Z', 'modified_at', '2024-02-20T09:00:00Z')),
    'candidates', jsonb_build_array(
      jsonb_build_object('zoho_id', 'ZT-1', 'display_id', 'ZR_1_CAND', 'full_name', 'Zoho One', 'email', 'zoho.one@example.test',
        'phone', '+389 71 111 111', 'linkedin_url', 'https://www.linkedin.com/in/zoho-one', 'source_key', 'linkedin_profile',
        'current_title', 'Analyst', 'skills', jsonb_build_array('SQL', 'Excel'), 'owner_zoho_id', 'U-1',
        'created_at', '2024-01-15T10:00:00Z', 'updated_at', '2024-05-06T10:00:00Z', 'last_activity_at', '2024-06-01T10:00:00Z',
        'custom', jsonb_build_object('education', jsonb_build_array(jsonb_build_object('institute', 'UKIM', 'degree', 'BSc')),
                                     'zoho', jsonb_build_object('status', 'Contacted'))),
      jsonb_build_object('zoho_id', 'ZT-2', 'display_id', 'ZR_2_CAND', 'full_name', 'Zed Twin', 'email', 'zed@example.test',
        'source_key', 'head_hunt', 'do_not_contact', true,
        'do_not_contact_reason', 'Zoho Recruit: NEVER to be contacted again (set by Alex Director on 01 Mar 2024)',
        'do_not_contact_at', '2024-03-02T10:00:00Z', 'do_not_contact_by_zoho_id', 'U-1', 'owner_zoho_id', 'U-2',
        'created_at', '2024-01-20T10:00:00Z', 'last_activity_at', (current_date - 89)::text),
      jsonb_build_object('zoho_id', 'ZT-3', 'display_id', 'ZR_3_CAND', 'full_name', 'Ked Lin', 'source_key', 'head_hunt',
        'created_at', '2024-01-05T10:00:00Z', 'last_activity_at', '2024-02-20T10:00:00Z', 'custom', null)),
    'applications', jsonb_build_array(
      jsonb_build_object('zoho_id', 'ZA-1', 'candidate_zoho_id', 'ZT-1', 'job_zoho_id', 'ZJ-1', 'stage_key', 'screening',
        'stale_closed', true, 'zoho_status', 'Contacted', 'zoho_stage', 'Screening',
        'received_at', '2024-01-16T10:00:00Z', 'modified_at', '2024-02-02T10:00:00Z', 'modified_by_zoho_id', 'U-1'),
      jsonb_build_object('zoho_id', 'ZA-2', 'candidate_zoho_id', 'ZT-2', 'job_zoho_id', 'ZJ-1', 'stage_key', 'hired',
        'zoho_status', 'Hired', 'received_at', '2024-01-21T10:00:00Z', 'modified_at', (current_date - 90)::text,
        'modified_by_zoho_id', 'U-1', 'hired_date', (current_date - 90)::text, 'hired_by_zoho_id', 'U-1'),
      jsonb_build_object('zoho_id', 'ZA-3', 'candidate_zoho_id', 'ZT-1', 'job_zoho_id', 'ZJ-2', 'stage_key', 'screening',
        'zoho_status', 'Interested', 'received_at', '2024-04-02T10:00:00Z', 'modified_at', '2024-05-05T10:00:00Z',
        'modified_by_zoho_id', 'U-2'),
      jsonb_build_object('zoho_id', 'ZA-4', 'candidate_zoho_id', 'ZT-3', 'job_zoho_id', 'ZJ-1', 'stage_key', 'hired',
        'zoho_status', 'Hired', 'received_at', '2024-01-06T10:00:00Z', 'modified_at', '2024-02-15T10:00:00Z',
        'hired_date', '2024-02-15'),
      jsonb_build_object('zoho_id', 'ZA-5', 'candidate_zoho_id', 'ZT-3', 'job_zoho_id', 'ZJ-3', 'stage_key', 'new',
        'stale_closed', true, 'zoho_status', 'Associated', 'received_at', '2024-01-06T11:00:00Z', 'modified_at', '2024-01-06T11:00:00Z',
        'custom', null)),
    'notes', jsonb_build_array(
      jsonb_build_object('zoho_id', 'ZN-1', 'application_zoho_id', 'ZA-3', 'kind', 'Call', 'body', 'Spoke on the phone.',
        'actor_zoho_id', 'U-1', 'actor_name', 'Alex Director', 'created_at', '2024-05-06T09:00:00Z'))
  )::text, false);
end $$;
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb; p jsonb := current_setting('app.zoho_payload')::jsonb; h jsonb; v_za1 uuid; v_za2 uuid; v_za3 uuid; v_za5 uuid;
begin
  -- Dry run: decides everything, writes nothing.
  r := public.import_zoho_recruit(p, false);
  assert not (r->>'committed')::boolean, 'dry run';
  assert (r->'counts'->>'candidates_created')::int = 3 and (r->'counts'->>'applications_created')::int = 5
     and (r->'counts'->>'jobs_created')::int = 3 and (r->'counts'->>'stale_closed')::int = 2
     and (r->'counts'->>'refused')::int = 0, 'dry-run counts: ' || (r->'counts')::text;
  assert (r->'counts'->>'users_unresolved')::int = 1 and jsonb_array_length(r->'users'->'unresolved') = 1
     and r->'users'->'unresolved'->0->>'email' = 'nobody@zoho.test', 'one unresolved user: ' || (r->'users')::text;
  select x into h from jsonb_array_elements(r->'hires') x where x->>'candidate' = 'Zed Twin';
  assert h->'proposal'->>'person_id' = '20000000-0000-0000-0000-000000000067' and h->'proposal'->>'match' = 'email',
    'the hire proposes Zed by email: ' || (r->'hires')::text;
  select x into h from jsonb_array_elements(r->'hires') x where x->>'candidate' = 'Ked Lin';
  assert h is not null and jsonb_typeof(h->'proposal') = 'null', 'no proposal without an identity: ' || (r->'hires')::text;
  assert (r->'counts'->>'possible_duplicates')::int = 1 and r->'possible_duplicates'->0->>'existing_name' = 'Lin Ked'
     and r->'possible_duplicates'->0->>'match' = 'name', 'a name match against a non-Zoho row is reported: ' || (r->'possible_duplicates')::text;
  assert (select count(*) from public.candidates where provider = 'zoho_recruit' and provider_ref like 'ZT-%') = 0,
    'the dry run wrote nothing';
  assert exists (select 1 from jsonb_array_elements(r->'assumptions') a where a->>'kind' = 'close_date_assumed' and a->>'job' = 'ZJ-3')
     and exists (select 1 from jsonb_array_elements(r->'assumptions') a where a->>'kind' = 'department' and a->>'department' = 'HUT 4')
     and exists (select 1 from jsonb_array_elements(r->'assumptions') a where a->>'kind' = 'synthesised_reason' and a->>'candidate' = 'ZT-2'),
    'assumptions are listed: ' || (r->'assumptions')::text;

  -- Commit.
  r := public.import_zoho_recruit(p, true);
  assert (r->>'committed')::boolean and (r->'counts'->>'candidates_created')::int = 3
     and (r->'counts'->>'events_created')::int = 6 and (r->'counts'->>'notes_created')::int = 1,
    'committed: ' || (r->'counts')::text;
  select id into v_za1 from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-1';
  select id into v_za2 from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-2';
  select id into v_za3 from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-3';
  select id into v_za5 from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-5';
  assert (select stage_key || '|' || withdrawn_reason || '|' || source_key from public.applications where id = v_za1)
         = 'withdrawn|Job closed|linkedin_profile', 'a stale row is withdrawn, job closed, with the candidate''s source';
  assert (select string_agg(coalesce(from_stage_key, 'null') || '>' || to_stage_key || '@' || created_at::text, ';' order by created_at)
          from public.application_events where application_id = v_za1 and kind = 'stage_change')
         = 'null>screening@' || '2024-02-02T10:00:00Z'::timestamptz::text || ';screening>withdrawn@' || '2024-03-01T00:00:00Z'::timestamptz::text,
    'two events: the Zoho stage on its date, then the close on the job''s date';
  assert (select stage_key from public.applications where id = v_za5) = 'withdrawn'
     and (select count(*) from public.application_events where application_id = v_za5) = 1
     and (select from_stage_key || '>' || to_stage_key || '@' || created_at::text from public.application_events where application_id = v_za5)
         = 'new>withdrawn@' || '2024-02-20T09:00:00Z'::timestamptz::text
     and (select (custom->'zoho'->>'close_date_assumed')::boolean from public.applications where id = v_za5),
    'a stale row at new gets one event dated the job''s modified time, close date assumed';
  assert (select created_at from public.application_events where application_id = v_za2 and to_stage_key = 'hired')
         = ((current_date - 90)::timestamp at time zone 'UTC'), 'the hire is dated its hired date at 00:00 UTC';
  assert (select custom->'zoho'->'proposed_person'->>'id' from public.applications where id = v_za2)
         = '20000000-0000-0000-0000-000000000067'
     and (select employment_period_id from public.applications where id = v_za2) is null,
    'the proposal is on the row; nothing is linked until HR confirms';
  assert (select count(*) from public.application_events where application_id = v_za3 and kind = 'note'
          and actor_id = '20000000-0000-0000-0000-000000000001' and body like '[Zoho Call · 06 May 2024 · Alex Director] Spoke on the phone.') = 1,
    'the note carries the Zoho prefix and the resolved actor';
  assert (select do_not_contact and do_not_contact_at = '2024-03-02T10:00:00Z'::timestamptz
                 and do_not_contact_by = '20000000-0000-0000-0000-000000000001'
          from public.candidates where provider = 'zoho_recruit' and provider_ref = 'ZT-2'),
    'the contact rule comes in as given';
  assert (select last_activity_at from public.candidates where provider = 'zoho_recruit' and provider_ref = 'ZT-1')
         = '2024-06-01T10:00:00Z'::timestamptz, 'last activity is Zoho''s';
  assert (select sourced_by from public.candidates where provider = 'zoho_recruit' and provider_ref = 'ZT-1')
         = '20000000-0000-0000-0000-000000000001'
     and (select custom->'education'->0->>'institute' from public.candidates where provider = 'zoho_recruit' and provider_ref = 'ZT-1') = 'UKIM',
    'owner resolved, custom kept';
  assert (select status || '|' || (custom->'zoho'->>'department') from public.jobs where custom->'zoho'->>'id' = 'ZJ-1') = 'filled|HUT 4',
    'the job keeps its Zoho facts';
  assert (select custom from public.candidates where provider = 'zoho_recruit' and provider_ref = 'ZT-3') = '{}'::jsonb
     and (select jsonb_typeof(custom) || '|' || (custom->'zoho'->>'display_id') from public.jobs where custom->'zoho'->>'id' = 'ZJ-2')
         = 'object|ZR_2_JOB',
    'a JSON-null custom imports as an object';
  assert exists (select 1 from public.activity_log where entity_type = 'zoho_recruit_import'
                 and actor_person_id = '20000000-0000-0000-0000-000000000004'), 'the import is logged';

  -- Commit again: everything is skipped, nothing new.
  r := public.import_zoho_recruit(p, true);
  assert (r->'counts'->>'candidates_skipped')::int = 3 and (r->'counts'->>'applications_skipped')::int = 5
     and (r->'counts'->>'jobs_skipped')::int = 3 and (r->'counts'->>'candidates_created')::int = 0
     and (r->'counts'->>'events_created')::int = 0 and (r->'counts'->>'notes_created')::int = 0,
    'a re-run skips: ' || (r->'counts')::text;
  assert (select count(*) from public.candidates where provider = 'zoho_recruit' and provider_ref like 'ZT-%') = 3
     and (select count(*) from public.applications where source_provider = 'zoho_recruit') = 5
     and (select count(*) from public.application_events where application_id in (v_za1, v_za2, v_za3, v_za5)) = 6,
    'no new rows on a re-run';

  -- An unknown company refuses the commit and writes nothing.
  begin
    perform public.import_zoho_recruit(jsonb_set(p, '{jobs}', (select jsonb_agg(j || '{"company_code":"ZZ"}'::jsonb)
                                                              from jsonb_array_elements(p->'jobs') j)), true);
    raise exception 'FAIL: committed with an unknown company';
  exception when raise_exception then
    if sqlerrm not like '%Import refused: % rows have problems. Fix the extract and run again.%' then raise; end if;
  end;
  assert (select count(*) from public.jobs where custom->'zoho'->>'id' like 'ZJ-%') = 3, 'nothing written on a refusal';
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex
set role authenticated;
do $$
begin
  begin
    perform public.import_zoho_recruit(current_setting('app.zoho_payload')::jsonb, false);
    raise exception 'FAIL: a non-admin ran the import';
  exception when insufficient_privilege then
    if sqlerrm not like '%Importing from Zoho Recruit needs platform admin access.%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '';

-- An open application from another source (HR added the same person to an
-- imported job by hand between runs) refuses the Zoho row in pass 1, named,
-- not as a wrapped unique violation in pass 2.
do $$
declare v_open uuid;
begin
  insert into public.applications (job_id, company_id, candidate_id, stage_key)
    select j.id, j.company_id, c.id, 'screening'
    from public.jobs j, public.candidates c
    where j.custom->'zoho'->>'id' = 'ZJ-2' and c.provider = 'zoho_recruit' and c.provider_ref = 'ZT-2'
    returning id into v_open;
  perform set_config('app.zoho_open_app', v_open::text, false);
end $$;
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb; p jsonb;
begin
  p := jsonb_set(current_setting('app.zoho_payload')::jsonb, '{applications}',
         (current_setting('app.zoho_payload')::jsonb)->'applications' || jsonb_build_object(
           'zoho_id', 'ZA-6', 'candidate_zoho_id', 'ZT-2', 'job_zoho_id', 'ZJ-2', 'stage_key', 'screening',
           'zoho_status', 'Contacted', 'received_at', '2024-06-01T10:00:00Z', 'modified_at', '2024-06-02T10:00:00Z'));
  r := public.import_zoho_recruit(p, false);
  assert (r->'counts'->>'refused')::int = 1 and (r->'counts'->>'applications_skipped')::int = 5
     and (r->'counts'->>'applications_created')::int = 0, 'the hand-made open application refuses ZA-6: ' || (r->'counts')::text;
  assert (select count(*) from jsonb_array_elements(r->'rows') x
          where x->>'kind' = 'application' and x->>'ref' = 'ZA-6'
            and x->'problems'->>0 = format('already has an open application for this job (id %s)', current_setting('app.zoho_open_app'))) = 1,
    'the refusal names the open application: ' || (r->'rows')::text;
  begin
    perform public.import_zoho_recruit(p, true);
    raise exception 'FAIL: committed over an open application';
  exception when raise_exception then
    if sqlerrm not like '%Import refused: 1 rows have problems.%' then raise; end if;
  end;
  assert (select count(*) from public.applications where source_provider = 'zoho_recruit') = 5, 'nothing written';
end $$;
reset role;

-- 13. HR confirms the employee record for an imported hire.
set app.test_uid = '00000000-0000-0000-0000-000000000001';  -- Alex (employment.edit in A)
set role authenticated;
do $$
declare r jsonb; v_za2 uuid; v_za3 uuid;
begin
  select id into v_za2 from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-2';
  select id into v_za3 from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-3';
  perform set_config('app.za4', (select id::text from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-4'), false);
  r := public.link_hired_application(v_za2, '20000000-0000-0000-0000-000000000067');
  assert (r->>'linked')::boolean and r->>'employment_period_id' = '30000000-0000-0000-0000-000000000067'
     and r->>'person_id' = '20000000-0000-0000-0000-000000000067', 'linked to Zed''s A period: ' || r::text;
  assert (select employment_period_id from public.applications where id = v_za2) = '30000000-0000-0000-0000-000000000067',
    'the application carries the period';
  assert exists (select 1 from public.application_events where application_id = v_za2 and kind = 'note'
                 and actor_id = '20000000-0000-0000-0000-000000000001'
                 and body = 'Linked to the employee record of Zed Hired by Alex Director.'), 'a note records the link';
  begin
    perform public.link_hired_application(v_za2, '20000000-0000-0000-0000-000000000067');
    raise exception 'FAIL: linked twice';
  exception when invalid_parameter_value then
    if sqlerrm not like '%This application is already linked to an employee record.%' then raise; end if;
  end;
  begin
    perform public.link_hired_application(v_za3, '20000000-0000-0000-0000-000000000067');
    raise exception 'FAIL: linked a screening application';
  exception when invalid_parameter_value then
    if sqlerrm not like '%Only hired applications can be linked to an employee record.%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000005';  -- Bea
set role authenticated;
do $$
begin
  begin
    -- Bea cannot even read the A application; the id comes from Alex's block.
    perform public.link_hired_application(current_setting('app.za4')::uuid, '20000000-0000-0000-0000-000000000067');
    raise exception 'FAIL: Bea linked a hire in A';
  exception when insufficient_privilege then
    if sqlerrm not like '%Linking a hire needs the "Edit employment information" capability in this company.%' then raise; end if;
  end;
end $$;
reset role;
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb; v_za4 uuid;
begin
  select id into v_za4 from public.applications where source_provider = 'zoho_recruit' and provider_ref = 'ZA-4';
  r := public.link_hired_application(v_za4, null);
  assert not (r->>'linked')::boolean, 'declined: ' || r::text;
  assert (select jsonb_typeof(custom->'zoho'->'proposed_person') = 'null'
                 and custom->'zoho'->>'link_declined_by' = '20000000-0000-0000-0000-000000000004'
          from public.applications where id = v_za4), 'the proposal is cleared and the decline recorded';
end $$;
reset role;

-- 14. Tail: Omar is back to what he held before this block.
set app.test_uid = '';
delete from public.grant_capabilities gc using omar_added a
  where gc.grant_id = a.grant_id and gc.capability_key = a.capability_key;
drop table omar_added;

-- ================================================================ 0068
-- Search by words (plan 053): every word of the query's key is a word-prefix
-- of some word of the candidate's key, order-free. The 0067 fixtures stand;
-- Ada (platform admin, so a pool holder everywhere) adds four records through
-- upsert_sourced_candidate — the door the app uses — and searches as herself.
set app.test_uid = '00000000-0000-0000-0000-000000000004';  -- Ada
set role authenticated;
do $$
declare r jsonb; v_elena uuid; v_marija uuid; v_ana uuid; v_test uuid;
begin
  r := public.upsert_sourced_candidate('manual', null, '{"full_name":"Élena Marija Trajkovska"}');
  assert r->>'action' = 'created', 'Élena is created: ' || r::text;
  v_elena := (r->>'id')::uuid;
  assert (select name_key from public.candidates where id = v_elena) = 'elena marija trajkovska',
    'the stored key is folded, lower-cased and sorted';
  r := public.upsert_sourced_candidate('manual', null, '{"full_name":"Marija Trajkovski"}');
  assert r->>'action' = 'created', 'a near namesake is a different key, so no match: ' || r::text;
  v_marija := (r->>'id')::uuid;
  r := public.upsert_sourced_candidate('manual', null, '{"full_name":"Ana Ilievska"}');
  assert r->>'action' = 'created', 'Ana is created: ' || r::text;
  v_ana := (r->>'id')::uuid;
  r := public.upsert_sourced_candidate('manual', null, '{"full_name":"Pool Person Test"}');
  assert r->>'action' = 'created', 'the three-word pool name is created: ' || r::text;
  v_test := (r->>'id')::uuid;
  assert (select name_key from public.candidates where id = v_test) = 'person pool test',
    'P1 ("Pool Person") and this one are different keys';

  -- 1. Two prefixes, out of order, folded on the stored side.
  r := public.search_candidates('{"q":"Traj Mar"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::uuid = v_elena),
    'Traj Mar finds Élena Marija Trajkovska: ' || r::text;
  -- 2. Folded on the query side: "elena" is the key of "Élena".
  r := public.search_candidates('{"q":"elena traj"}');
  assert (r->>'total')::int = 1
     and (r->'rows'->0->>'id')::uuid = v_elena, 'elena traj finds only Élena: ' || r::text;
  -- 3. Every word must match, so a word from another person excludes both.
  r := public.search_candidates('{"q":"Trajkovska Ana"}');
  assert (r->>'total')::int = 0, 'Trajkovska Ana finds neither Élena nor Ana Ilievska: ' || r::text;
  assert not exists (select 1 from jsonb_array_elements(r->'rows') x
                     where (x->>'id')::uuid in (v_elena, v_ana, v_marija)), 'and names no one: ' || r::text;
  -- 4. The defect that started plan 053: a partial multi-word query whose
  -- words are not a contiguous run of the sorted key.
  r := public.search_candidates('{"q":"Pool Test"}');
  assert (r->>'total')::int = 1 and (r->'rows'->0->>'id')::uuid = v_test,
    'Pool Test finds Pool Person Test: ' || r::text;
  r := public.search_candidates('{"q":"test pool"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::uuid = v_test),
    'the order of the query words does not matter: ' || r::text;
  r := public.search_candidates('{"q":"Per Po"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::uuid = v_test)
     and exists (select 1 from jsonb_array_elements(r->'rows') x
                 where x->>'id' = '80000000-0000-0000-0000-000000000671'),
    'two short prefixes find Pool Person Test and P1: ' || r::text;
  r := public.search_candidates('{"q":"Pool Testx"}');
  assert (r->>'total')::int = 0, 'a prefix test is not a substring test: Testx matches nothing: ' || r::text;

  -- 5. The other predicates are untouched: an email fragment and a skill.
  r := public.search_candidates('{"q":"newpool@"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'full_name' = 'New Pool'),
    'an email fragment still finds New Pool: ' || r::text;
  r := public.search_candidates('{"q":"Excel"}');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'full_name' = 'Zoho One'),
    'a skill still finds the imported Zoho row: ' || r::text;

  -- 6. Paging arithmetic is untouched: total counts the matches, and the
  -- first page carries them all.
  r := public.search_candidates('{"q":"traj"}');
  assert (r->>'total')::int = 2 and jsonb_array_length(r->'rows') = 2
     and exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::uuid = v_elena)
     and exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::uuid = v_marija),
    'one prefix, both namesakes, total = rows: ' || r::text;
  r := public.search_candidates('{"q":"traj","limit":1}');
  assert (r->>'total')::int = 2 and jsonb_array_length(r->'rows') = 1, 'total ignores the page size: ' || r::text;
  r := public.search_candidates('{"q":"traj","limit":1,"offset":1}');
  assert (r->>'total')::int = 2 and jsonb_array_length(r->'rows') = 1, 'and the offset: ' || r::text;
end $$;
reset role;
set app.test_uid = '';

select 'SMOKE TESTS PASSED' as result;
