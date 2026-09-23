-- Run after smoke.sql on the disposable local database only.
begin;
reset role;
set app.test_uid = '';
insert into public.jobs (id, company_id, title, status) values
  ('70000000-0000-0000-0000-000000000811', '10000000-0000-0000-0000-00000000000b', 'Delete test job', 'open');
insert into public.candidates (id, full_name) values
  ('80000000-0000-0000-0000-000000000811', 'Delete test candidate');
insert into public.applications (id, job_id, company_id, candidate_id, stage_key, employment_period_id) values
  ('90000000-0000-0000-0000-000000000811', '70000000-0000-0000-0000-000000000811',
   '10000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-000000000811', 'hired',
   '30000000-0000-0000-0000-000000000005');
insert into public.application_events (application_id, kind, body) values
  ('90000000-0000-0000-0000-000000000811', 'note', 'Test history');

set role authenticated;
set app.test_uid = '00000000-0000-0000-0000-000000000001';
do $$ begin
  begin
    perform public.delete_job_application('90000000-0000-0000-0000-000000000811');
    raise exception 'FAIL: another company deleted the application';
  exception when insufficient_privilege then null;
  end;
end $$;

set app.test_uid = '00000000-0000-0000-0000-000000000005';
select public.delete_job_application('90000000-0000-0000-0000-000000000811');
reset role;
do $$ begin
  assert not exists (select 1 from public.applications where id = '90000000-0000-0000-0000-000000000811');
  assert not exists (select 1 from public.application_events where application_id = '90000000-0000-0000-0000-000000000811');
  assert exists (select 1 from public.candidates where id = '80000000-0000-0000-0000-000000000811');
  assert exists (select 1 from public.employment_periods where id = '30000000-0000-0000-0000-000000000005');
  assert exists (select 1 from public.jobs where id = '70000000-0000-0000-0000-000000000811');
end $$;
rollback;
select 'APPLICATION DELETION TESTS PASSED' as result;
