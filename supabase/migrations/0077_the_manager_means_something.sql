-- 0077_the_manager_means_something.sql
-- The manager, from a label into a person (plan 062).
--
-- Chasing why plan 061's manager could not reach the access card turned up
-- something larger: "manager" is a word this app writes down and never uses.
-- On live, at the time of writing:
--
--   * employments naming a manager .................. 0
--   * plan_tasks with an owner ...................... 0 of 42
--   * can a manager open a plan page? ............... no
--
-- And that is not one feature's problem. 0040 seeds four checklist lines with
-- `default_owner_role = 'manager'` — Team introduction, First 1:1, Handover
-- documented and accepted, Manager sign-off — and `plan_tasks` has always let
-- a task's owner read their own row, and My workspace has always listed tasks
-- by `owner_id`. Both ends were built. Nothing joined them, so those four
-- lines could never reach anybody, and the "My tasks" card on the workspace
-- has been empty for every person since the day it shipped.
--
-- This joins them:
--   1. a starting plan resolves each line's owner ROLE to an actual person;
--   2. a plan is readable by the manager named on its employment, so the
--      person who owns a line can open the page the line lives on.
--
-- Recording the managers is still data entry nobody can skip — the employee
-- record's corrections already edit `manager_id`. Until that is done this
-- changes nothing, which is why it is safe to apply before it is done.

-- ------------------------------------------------------------ the owner
-- Which person a line's role means, for this plan. Null where the role has
-- no obvious person — `finance` names no owner anywhere yet, and an
-- unassigned line is honest where a wrong one is not.
create or replace function app.owner_for_role(p_plan_id uuid, p_role text) returns uuid
language sql stable security definer set search_path = public as $$
  select case p_role
    -- Whoever started the plan; the column has been on `plans` since 0004.
    when 'hr' then p.hr_owner_id
    -- The line is the person's own: "read the policies", "bring your ID".
    when 'employee' then p.person_id
    when 'manager' then (select ep.manager_id from public.employment_periods ep
                          where ep.id = p.employment_period_id)
    when 'it' then (select wo.person_id from public.workflow_owners wo
                     where wo.company_id = p.company_id and wo.role_key = 'it_owner')
    else null
  end
  from public.plans p where p.id = p_plan_id
$$;

-- `copy_template_tasks` gains one column. Everything else about it is
-- unchanged: same rows, same dates, same order.
create or replace function app.copy_template_tasks(p_plan_id uuid, p_template_id uuid, p_anchor date) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into public.plan_tasks
      (plan_id, template_task_id, task_key, title, description, owner_role, owner_id, phase_key,
       due_date, critical, requires_evidence, sort_order)
    select p_plan_id, tt.id, tt.key, tt.title, tt.description, tt.default_owner_role,
           app.owner_for_role(p_plan_id, tt.default_owner_role),
           tt.phase_key, p_anchor + tt.due_offset_days, tt.critical,
           tt.requires_evidence, tt.sort_order
    from public.template_tasks tt
    where tt.template_id = p_template_id and tt.archived_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ----------------------------------------------------------- the backfill
-- The plans already running get their owners too, or the change would only
-- ever help somebody hired after today. Only where the line has no owner
-- already: a line somebody was given by hand stays theirs.
update public.plan_tasks pt
   set owner_id = app.owner_for_role(pt.plan_id, pt.owner_role)
  from public.plans p
 where pt.plan_id = p.id
   and pt.owner_id is null
   and p.status = 'in_progress'
   and app.owner_for_role(pt.plan_id, pt.owner_role) is not null;

-- ------------------------------------------------------------ the lookup
-- Asked by the policy below, and SECURITY DEFINER because it has to be: a
-- policy's subquery runs as the querying role, so a plain `exists` over
-- `employment_periods` would ask the manager to prove they are the manager by
-- reading a row they are not allowed to read. It answers one yes-or-no about
-- the caller and nothing else.
create or replace function app.manages_employment(p_period uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_period is not null and exists (
    select 1 from public.employment_periods ep
     where ep.id = p_period and ep.manager_id = app.current_person_id())
$$;

-- --------------------------------------------------------------- the plan
-- A manager may read the plan of somebody they manage. Not the company's
-- plans — theirs. `tasks.view` remains what lets HR see everybody's, and
-- writing is unchanged: `tasks.assign` / `tasks.complete`, plus the owner of
-- a line, which `plan_tasks` has always allowed.
drop policy sel on public.plans;
create policy sel on public.plans for select to authenticated
  using (
    app.is_self(person_id)
    or app.has_capability(company_id, 'tasks.view')
    or app.manages_employment(employment_period_id)
  );
