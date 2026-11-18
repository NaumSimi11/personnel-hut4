-- 0114: three hiring roles only — Recruiter, Hiring manager, HR (board card B3, decision D3).
--
-- 0107's hiring team offered Recruiter, Interviewer, Assessor, Panel and
-- Director / CEO. The decision keeps three roles, and the board's stage
-- owners follow (the technical test, Interview 2 and the final interview go
-- to the hiring manager). Every team member still sees the job's candidates
-- and scores its interviews, as 0107 set up; only the names change.
--
-- A member under a dropped role becomes a hiring manager on the team: they
-- were there to assess or interview, which is the hiring manager's side.

begin;

alter table public.job_team drop constraint job_team_role_check;
update public.job_team set role = 'hiring_manager' where role in ('interviewer', 'assessor', 'panel', 'director');
alter table public.job_team
  add constraint job_team_role_check check (role in ('recruiter', 'hiring_manager', 'hr')),
  alter column role set default 'recruiter';

-- 0107's notice, with the role in words rather than its key.
create or replace function app.notify_job_team() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_job record;
begin
  if new.person_id = app.current_person_id() then return new; end if;
  select id, company_id, title into v_job from public.jobs where id = new.job_id;
  perform app.notify(new.person_id, v_job.company_id, 'hiring.team',
    'You are on the hiring team: ' || v_job.title,
    'Role: ' || case new.role when 'recruiter' then 'Recruiter' when 'hiring_manager' then 'Hiring manager' when 'hr' then 'HR' else new.role end
      || ' · you can see its candidates',
    '/hiring/jobs/' || v_job.id, 'job', v_job.id, 'hiring.team:' || v_job.id || ':' || new.person_id);
  return new;
end $$;

commit;
