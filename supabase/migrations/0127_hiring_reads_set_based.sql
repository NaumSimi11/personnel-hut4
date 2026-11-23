-- 0127 — the hiring lists load again (23 Nov).
--
-- Applicants on "All stages" returned 500: 4,157 applications took 8.1 s
-- as a signed-in user, past the 8 s limit for `authenticated`. Every row
-- ran has_capability, is_hiring_manager_of and hidden_from_manager on its
-- own, and the embedded candidates, files, interviews and offers did the
-- same again.
--
-- Same rules, worked out once per query: the companies where I hold a
-- capability, the jobs I manage or sit on the team of, and the candidates
-- hidden from me as their line manager. Each policy reads those sets
-- through an uncorrelated `(select …)`, which Postgres runs once.
-- Who sees what does not change; supabase/tests/smoke.sql proves it.

-- ------------------------------------------------------------- the sets

/** Companies where I hold `cap` through a grant (admins are checked apart). */
create or replace function app.companies_with(cap text)
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select g.company_id
    from public.access_grants g
    join public.grant_capabilities gc on gc.grant_id = g.id
   where not app.password_change_pending()
     and g.person_id = app.current_person_id()
     and gc.capability_key = cap
$$;

/** Jobs I see as their hiring manager (with candidates.assigned) or as a team member. */
create or replace function app.my_hm_job_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select j.id
    from public.jobs j
   where j.hiring_manager_id = app.current_person_id()
     and app.has_capability(j.company_id, 'candidates.assigned')
  union
  select t.job_id
    from public.job_team t
   where t.person_id = app.current_person_id()
$$;

/** Applications on those jobs. */
create or replace function app.my_hm_application_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select a.id from public.applications a
   where a.job_id in (select app.my_hm_job_ids())
$$;

/** Candidates on those jobs. */
create or replace function app.my_hm_candidate_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select a.candidate_id from public.applications a
   where a.job_id in (select app.my_hm_job_ids())
$$;

/** Candidates with an application in a company where I hold candidates.view. */
create or replace function app.viewable_candidate_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select a.candidate_id from public.applications a
   where app.is_admin()
      or a.company_id in (select app.companies_with('candidates.view'))
$$;

/** Internal candidates whose line manager I am (pre-start or active): hidden from me before Offer. */
create or replace function app.candidates_hidden_from_me()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select c.id
    from public.candidates c
    join public.employment_periods ep on ep.person_id = c.person_id
   where not app.is_admin()
     and c.person_id is not null
     and ep.manager_id = app.current_person_id()
     and ep.status in ('pre_start', 'active')
$$;

revoke all on function app.companies_with(text) from public;
revoke all on function app.my_hm_job_ids() from public;
revoke all on function app.my_hm_application_ids() from public;
revoke all on function app.my_hm_candidate_ids() from public;
revoke all on function app.viewable_candidate_ids() from public;
revoke all on function app.candidates_hidden_from_me() from public;
grant execute on function app.companies_with(text) to authenticated, service_role;
grant execute on function app.my_hm_job_ids() to authenticated, service_role;
grant execute on function app.my_hm_application_ids() to authenticated, service_role;
grant execute on function app.my_hm_candidate_ids() to authenticated, service_role;
grant execute on function app.viewable_candidate_ids() to authenticated, service_role;
grant execute on function app.candidates_hidden_from_me() to authenticated, service_role;

-- ----------------------------------------------------------- the policies

alter policy sel on public.applications
  using ((select app.is_admin()) or company_id in (select app.companies_with('candidates.view')));
alter policy sel_hm on public.applications
  using (job_id in (select app.my_hm_job_ids()));
alter policy hide_from_manager on public.applications
  using (stage_key in ('offer', 'hired') or candidate_id not in (select app.candidates_hidden_from_me()));

alter policy sel on public.candidates
  using ((select app.can_source_candidates()) or id in (select app.viewable_candidate_ids()));
alter policy sel_hm on public.candidates
  using (id in (select app.my_hm_candidate_ids()));

alter policy sel on public.jobs
  using ((select app.is_admin()) or company_id in (select app.companies_with('jobs.view')));

alter policy sel on public.application_files
  using ((select app.is_admin()) or company_id in (select app.companies_with('candidates.view')));
alter policy sel_hm on public.application_files
  using (application_id in (select app.my_hm_application_ids()));

alter policy sel on public.interviews
  using ((select app.is_admin()) or company_id in (select app.companies_with('candidates.view')));
alter policy sel_hm on public.interviews
  using (application_id in (select app.my_hm_application_ids()));

alter policy sel on public.offers
  using ((select app.is_admin()) or company_id in (select app.companies_with('candidates.view')));
alter policy sel_hm on public.offers
  using (application_id in (select app.my_hm_application_ids()));
