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

reset role;
set app.test_uid = '';

select 'SMOKE TESTS PASSED' as result;
