-- 0059_hiring_managers.sql
-- Who may be named the hiring manager on a request.
--
-- The dropdown listed every person in the holding — several hundred rows,
-- most of whom have no business owning a vacancy, and the name that lands there
-- decides who the candidate queue chases. Naming someone who cannot even see
-- the job is how a request sits untouched for a fortnight.
--
-- The rule is the one the maintainer described: HR and above. In capabilities
-- that means anyone who can work recruitment or employee records in that
-- company — candidates.review, jobs.approve, jobs.edit, employment.edit,
-- people.view, tasks.assign — plus platform admins, who can do all of it
-- everywhere.
--
-- Deliberately a capability test rather than a job title: "manager" is not a
-- thing this system records, and a company that hands recruitment to an office
-- manager should see them here without anyone renaming a role.

create or replace function public.hiring_managers(p_company_id uuid)
returns table (id uuid, full_name text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.full_name
  from public.people p
  where exists (
      select 1
      from public.access_grants g
      join public.grant_capabilities gc on gc.grant_id = g.id
      where g.person_id = p.id
        and g.company_id = p_company_id
        and gc.capability_key in (
          'candidates.review', 'jobs.approve', 'jobs.edit',
          'employment.edit', 'people.view', 'tasks.assign')
    )
    or exists (select 1 from public.platform_admins pa where pa.person_id = p.id)
  order by p.full_name
$$;
grant execute on function public.hiring_managers(uuid) to authenticated;
