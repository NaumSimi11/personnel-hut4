-- 0007_seed_reference_data.sql
-- Reference/config data only — no demo companies or people. Capability keys
-- match prototype/app.js exactly so the design prototype and the real system
-- share one vocabulary. Extending any of these later is an INSERT, not DDL.

-- ------------------------------------------------------------- capabilities
insert into public.capabilities (key, group_name, label, sensitive, sort_order) values
  ('people.view',        'Employee records', 'View employee directory', false, 10),
  ('personal.view',      'Employee records', 'View private personal details', true, 20),
  ('employment.edit',    'Employee records', 'Edit employment information', false, 30),
  ('departure.start',    'Employee records', 'Start offboarding', false, 40),
  ('payroll.summary',    'Compensation & payroll', 'View company payroll totals', true, 10),
  ('payroll.individual', 'Compensation & payroll', 'View individual payroll', true, 20),
  ('salary.view',        'Compensation & payroll', 'View individual salaries', true, 30),
  ('salary.propose',     'Compensation & payroll', 'Propose salary changes', true, 40),
  ('salary.approve',     'Compensation & payroll', 'Approve salary changes', true, 50),
  ('payroll.approve',    'Compensation & payroll', 'Approve payroll', true, 60),
  ('payroll.export',     'Compensation & payroll', 'Export payroll', true, 70),
  ('jobs.view',          'Recruitment', 'View company jobs', false, 10),
  ('jobs.request',       'Recruitment', 'Request a hire', false, 20),
  ('jobs.approve',       'Recruitment', 'Approve hiring requests', false, 30),
  ('jobs.edit',          'Recruitment', 'Edit job descriptions', false, 40),
  ('jobs.publish',       'Recruitment', 'Publish job listings', false, 50),
  ('candidates.view',    'Recruitment', 'View company applications', false, 60),
  ('candidates.review',  'Recruitment', 'Record interview feedback', false, 70),
  ('offer.approve',      'Recruitment', 'Approve offers', false, 80),
  ('documents.view',     'Documents & onboarding', 'View employment documents', true, 10),
  ('documents.request',  'Documents & onboarding', 'Request employee documents', false, 20),
  ('documents.upload',   'Documents & onboarding', 'Upload employment documents', false, 25),
  ('policies.publish',   'Documents & onboarding', 'Publish company policies', false, 28),
  ('tasks.view',         'Documents & onboarding', 'View onboarding progress', false, 30),
  ('tasks.assign',       'Documents & onboarding', 'Assign onboarding tasks', false, 40),
  ('tasks.complete',     'Documents & onboarding', 'Complete assigned tasks', false, 50),
  ('it.view',            'Equipment & IT', 'View IT and equipment requests', false, 10),
  ('it.assign',          'Equipment & IT', 'Assign requests', false, 20),
  ('it.complete',        'Equipment & IT', 'Confirm setup and equipment handoff', false, 30),
  ('marketing.view',     'Recruitment marketing', 'View approved public job briefs', false, 10),
  ('marketing.draft',    'Recruitment marketing', 'Draft promotional content', false, 20),
  ('marketing.approve',  'Recruitment marketing', 'Approve promotional content', false, 30),
  ('marketing.publish',  'Recruitment marketing', 'Publish company posts', false, 40),
  ('projects.view',      'Projects & work', 'View project assignments (read-only)', false, 10),
  ('integration.view',   'Administration', 'View integration status', false, 10),
  ('integration.manage', 'Administration', 'Manage company connections', true, 20),
  ('access.manage',      'Administration', 'Manage company access', true, 30);

insert into public.capability_dependencies (capability_key, requires_key) values
  ('personal.view','people.view'), ('employment.edit','people.view'),
  ('departure.start','people.view'),
  ('salary.propose','salary.view'), ('salary.approve','salary.view'),
  ('payroll.approve','payroll.individual'), ('payroll.export','payroll.individual'),
  ('jobs.request','jobs.view'), ('jobs.approve','jobs.view'),
  ('jobs.edit','jobs.view'), ('jobs.publish','jobs.view'),
  ('candidates.review','candidates.view'), ('offer.approve','candidates.view'),
  ('documents.request','documents.view'), ('documents.upload','documents.view'),
  ('tasks.assign','tasks.view'), ('tasks.complete','tasks.view'),
  ('it.assign','it.view'), ('it.complete','it.view'),
  ('marketing.draft','marketing.view'), ('marketing.approve','marketing.view'),
  ('marketing.publish','marketing.view'), ('integration.manage','integration.view');

-- ------------------------------------------------------------------ presets
insert into public.permission_presets (name, description, is_system) values
  ('Company Director', 'Company oversight without payroll or salary visibility', true),
  ('Company HR',       'Full HR operations within one company', true),
  ('Holding HR',       'Company HR plus access administration and approvals', true),
  ('Finance',          'Payroll and salary visibility, no HR editing', true),
  ('IT',               'Equipment and setup requests plus own tasks', true),
  ('Marketing',        'Draft promotional content from approved briefs', true),
  ('Hiring Manager',   'Own openings and applicants, team onboarding view', true),
  ('Recruiter',        'Prepare, publish and evaluate for assigned companies', true),
  ('Employee',         'Self-service only; personal record and own tasks', true),
  ('No access',        'No capabilities granted', true);

with p as (select id, name from public.permission_presets),
caps(preset, cap) as (values
  ('Company Director','people.view'),('Company Director','jobs.view'),
  ('Company Director','jobs.request'),('Company Director','jobs.approve'),
  ('Company Director','candidates.view'),('Company Director','tasks.view'),
  ('Company Director','projects.view'),
  ('Company HR','people.view'),('Company HR','personal.view'),
  ('Company HR','employment.edit'),('Company HR','departure.start'),
  ('Company HR','jobs.view'),('Company HR','jobs.request'),('Company HR','jobs.edit'),
  ('Company HR','candidates.view'),('Company HR','candidates.review'),
  ('Company HR','documents.view'),('Company HR','documents.request'),
  ('Company HR','documents.upload'),
  ('Company HR','tasks.view'),('Company HR','tasks.assign'),('Company HR','tasks.complete'),
  ('Company HR','integration.view'),('Company HR','projects.view'),
  ('Holding HR','people.view'),('Holding HR','personal.view'),
  ('Holding HR','employment.edit'),('Holding HR','departure.start'),
  ('Holding HR','jobs.view'),('Holding HR','jobs.request'),('Holding HR','jobs.edit'),
  ('Holding HR','jobs.approve'),
  ('Holding HR','candidates.view'),('Holding HR','candidates.review'),
  ('Holding HR','offer.approve'),
  ('Holding HR','documents.view'),('Holding HR','documents.request'),
  ('Holding HR','documents.upload'),('Holding HR','policies.publish'),
  ('Holding HR','tasks.view'),('Holding HR','tasks.assign'),('Holding HR','tasks.complete'),
  ('Holding HR','integration.view'),('Holding HR','access.manage'),
  ('Holding HR','projects.view'),
  ('Finance','people.view'),('Finance','salary.view'),
  ('Finance','payroll.summary'),('Finance','payroll.individual'),
  ('IT','people.view'),('IT','it.view'),('IT','it.assign'),('IT','it.complete'),
  ('IT','tasks.view'),('IT','tasks.complete'),
  ('Marketing','marketing.view'),('Marketing','marketing.draft'),
  ('Hiring Manager','people.view'),('Hiring Manager','jobs.view'),
  ('Hiring Manager','jobs.request'),('Hiring Manager','candidates.view'),
  ('Hiring Manager','candidates.review'),('Hiring Manager','tasks.view'),
  ('Hiring Manager','projects.view'),
  ('Recruiter','people.view'),('Recruiter','jobs.view'),('Recruiter','jobs.edit'),
  ('Recruiter','jobs.publish'),('Recruiter','candidates.view'),
  ('Recruiter','candidates.review'),('Recruiter','marketing.view')
)
insert into public.preset_capabilities (preset_id, capability_key)
select p.id, caps.cap from caps join p on p.name = caps.preset;

-- --------------------------------------------------------------- vocabularies
insert into public.employment_statuses (key, label, counts_as_employed, sort_order) values
  ('draft','Draft',false,10), ('pre_start','Pre-start',true,20),
  ('active','Active',true,30), ('former','Former',false,40);

insert into public.employment_types (key, label, sort_order) values
  ('full_time','Full-time',10), ('part_time','Part-time',20),
  ('contractor','Contractor',30);

insert into public.pay_bases (key, label, sort_order) values
  ('annual','Annual',10), ('monthly','Monthly',20),
  ('daily','Daily',30), ('hourly','Hourly',40);

insert into public.application_stages (key, label, sort_order, is_terminal) values
  ('new','New',10,false), ('screening','Screening',20,false),
  ('interview','Interview',30,false), ('offer','Offer',40,false),
  ('hired','Hired',50,true), ('rejected','Rejected',60,true),
  ('withdrawn','Withdrawn',70,true);

insert into public.channels (key, label, kind) values
  ('careers','Company careers page','careers'),
  ('linkedin','LinkedIn','social'),
  ('indeed','Indeed','job_board'),
  ('other_manual','Other platform (manual record)','manual');

insert into public.providers (key, label, kind) values
  ('zoho_projects','Zoho Projects','projects'),
  ('leave_system','Existing leave system','leave'),
  ('linkedin_recruitment','LinkedIn recruitment (Apply Connect)','recruitment'),
  ('linkedin_pages','LinkedIn company pages','publishing'),
  ('indeed','Indeed Job Sync','recruitment');

insert into public.plan_phases (key, label, sort_order) values
  ('before_start','Before start',10), ('day_one','Day one',20),
  ('week_one','Week one',30), ('month_one','Month one',40);

insert into public.document_categories (key, label, person_scoped, sort_order) values
  ('employment_agreement','Employment agreement',true,10),
  ('amendment','Contract amendment',true,20),
  ('onboarding_form','Onboarding form',true,30),
  ('identification','Identification',true,40),
  ('other','Other',true,90);

insert into public.asset_types (key, label, is_physical) values
  ('laptop','Laptop',true), ('monitor','Monitor',true), ('phone','Phone',true),
  ('accessory','Accessory',true), ('software_license','Software license',false);

insert into public.workflow_roles (key, label) values
  ('hiring_approver','Approves hiring requests'),
  ('offer_approver','Approves offers'),
  ('marketing_reviewer','Reviews promotional content'),
  ('hr_owner','Owns HR operations'),
  ('it_owner','Owns IT setup and equipment');

-- --------------------------------------------- default onboarding template
with t as (
  insert into public.task_templates (company_id, kind, name)
  values (null, 'onboarding', 'Standard onboarding')
  returning id
)
insert into public.template_tasks
  (template_id, title, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order)
select t.id, v.* from t, (values
  ('Employment documents reviewed', 'hr',       'before_start', -3, true,  true,  10),
  ('Laptop and equipment handed over', 'it',    'before_start', -1, true,  false, 20),
  ('Work account and access confirmed', 'it',   'before_start', -1, true,  false, 30),
  ('First-day details shared', 'hr',            'before_start', -2, true,  false, 40),
  ('Team introduction completed', 'manager',    'day_one',       0, false, false, 50)
) as v(title, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order);
