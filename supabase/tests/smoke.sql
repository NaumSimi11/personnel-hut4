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

-- Audit trail captured the grant writes.
do $$
begin
  assert (select count(*) from public.activity_log where entity_type = 'access_grants') >= 2,
    'Audit log should record access grant changes';
  assert (select count(*) from public.activity_log where entity_type = 'workflow_owners') >= 1,
    'Audit log should record workflow owner changes';
end $$;

select 'SMOKE TESTS PASSED' as result;
