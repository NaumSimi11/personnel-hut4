-- 0121: every role outside HR's eight is cleaned out (18 Nov).
--
-- 0120 left the access roles at HR's eight (Employee, Finance, General
-- Administrator, Hiring Manager, IT, Marketing, No access, Recruiter). The
-- other role lists now follow them, and "HR" is not one of the eight: HR's
-- work goes to the General Administrator (decided 18 Nov).
--
--   * Workflow owners: General Administrator, IT, Marketing. "Owns HR
--     operations", "Approves hiring requests" and "Approves offers" go. Where a
--     company had an HR owner and no General Administrator, that person becomes
--     its General Administrator (Hut4: Ivana Frost). Nothing read the two
--     approver roles but the requests page's "Awaiting …" line, which now
--     names the General Administrator.
--   * A handover recipient that reached a removed role is pointed at the
--     person who held it, so it keeps going out (Hut4's "Accountant", with pay
--     and bank details, stays with that person, not with every General
--     Administrator).
--   * Hiring team: Recruiter, Hiring Manager, General Administrator.
--   * Checklist line owners keep their keys; an "hr" line now goes to the
--     company's General Administrator, or to whoever started the checklist
--     when none is named. The app shows the lines as General Administrator,
--     IT, Hiring Manager, Employee and Finance.

begin;

-- ------------------------------------------------------- workflow owners
insert into public.workflow_owners (company_id, role_key, person_id)
select o.company_id, 'general_admin', o.person_id
  from public.workflow_owners o
 where o.role_key = 'hr_owner'
on conflict (company_id, role_key) do nothing;

update public.handover_recipients h
   set kind = 'person', person_id = o.person_id, role_key = null, updated_at = now()
  from public.workflow_owners o
 where h.kind = 'role'
   and h.role_key in ('hr_owner', 'hiring_approver', 'offer_approver')
   and o.company_id = h.company_id and o.role_key = h.role_key;
-- One nobody held reached nobody; it goes.
delete from public.handover_recipients where kind = 'role' and role_key in ('hr_owner', 'hiring_approver', 'offer_approver');

delete from public.workflow_owners where role_key in ('hr_owner', 'hiring_approver', 'offer_approver');
delete from public.workflow_roles where key in ('hr_owner', 'hiring_approver', 'offer_approver');
update public.workflow_roles set label = 'IT' where key = 'it_owner';
update public.workflow_roles set label = 'Marketing' where key = 'marketing_reviewer';

-- A blocked IT request tells the General Administrator (0041 told the HR owner).
create or replace function app.notify_it_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := app.person_name(new.person_id);
  v_it uuid := (select person_id from public.workflow_owners where company_id = new.company_id and role_key = 'it_owner');
  v_ga uuid := (select person_id from public.workflow_owners where company_id = new.company_id and role_key = 'general_admin');
  v_it_mail text := (select it_notification_email from public.companies where id = new.company_id);
begin
  if tg_op = 'INSERT' then
    if v_it is not null and v_it is distinct from new.requested_by then
      perform app.notify(v_it, new.company_id, 'it.requested', 'IT request for ' || v_who || ': ' || new.title,
        coalesce('Due ' || to_char(new.due_at, 'DD Mon YYYY'), 'No due date') || ' · ' || new.kind,
        '/companies/' || new.company_id || '?tab=equipment', 'it_request', new.id, 'it.requested:' || new.id);
      if v_it_mail is not null then
        update public.notifications set email_to = v_it_mail, email_status = 'pending' where dedupe_key = 'it.requested:' || new.id || ':' || v_it;
      end if;
    end if;
    return new;
  end if;
  if new.status is not distinct from old.status then return new; end if;
  if new.status = 'blocked' and v_ga is not null then
    perform app.notify(v_ga, new.company_id, 'it.blocked', 'IT request blocked for ' || v_who || ': ' || new.title,
      coalesce(new.blocked_reason, ''), '/companies/' || new.company_id || '?tab=equipment', 'it_request', new.id, 'it.blocked:' || new.id || ':' || now(), true);
  elsif new.status = 'done' and new.requested_by is not null then
    perform app.notify(new.requested_by, new.company_id, 'it.done', 'IT request done for ' || v_who || ': ' || new.title,
      'by ' || app.person_name(coalesce(new.assignee_id, app.current_person_id())), '/people/' || new.person_id, 'it_request', new.id, 'it.done:' || new.id);
  end if;
  return new;
end $$;

-- The setup banner asks for a General Administrator where it asked for an HR owner.
create or replace function public.setup_gaps() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin boolean := app.is_admin();
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'can_fix', v_admin,
    'companies', coalesce((
      select jsonb_agg(g order by g->>'company_name')
        from (
          select jsonb_build_object(
                   'company_id', c.id,
                   'company_name', c.name,
                   'missing_roles', to_jsonb(array_remove(array[
                     case when not app.has_live_owner(c.id, 'it_owner') then 'it_owner' end,
                     case when not app.has_live_owner(c.id, 'general_admin') then 'general_admin' end], null)),
                   'missing_inboxes', to_jsonb(array_remove(array[
                     case when nullif(btrim(coalesce(c.it_notification_email, '')), '') is null then 'it' end,
                     case when nullif(btrim(coalesce(c.hr_notification_email, '')), '') is null then 'hr' end], null))) as g
            from public.companies c
           where v_admin or app.has_capability(c.id, 'employment.edit')
        ) x
       where jsonb_array_length(g->'missing_roles') > 0 or jsonb_array_length(g->'missing_inboxes') > 0), '[]'::jsonb));
end $$;

-- ---------------------------------------------------- checklist line owners
-- An "hr" line goes to the company's General Administrator, else to whoever
-- started the checklist (0077's rule until now).
create or replace function app.owner_for_role(p_plan_id uuid, p_role text) returns uuid
language sql stable security definer set search_path = public as $$
  select case p_role
    when 'hr' then coalesce(
      (select wo.person_id from public.workflow_owners wo join public.people pe on pe.id = wo.person_id
        where wo.company_id = p.company_id and wo.role_key = 'general_admin' and pe.archived_at is null),
      p.hr_owner_id)
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

-- Open "hr" lines move to the General Administrator now; a done line keeps who did it.
update public.plan_tasks t
   set owner_id = app.owner_for_role(t.plan_id, 'hr')
 where t.owner_role = 'hr' and t.status in ('open', 'blocked')
   and app.owner_for_role(t.plan_id, 'hr') is not null;

-- ------------------------------------------------------------ hiring team
alter table public.job_team drop constraint job_team_role_check;
update public.job_team set role = 'general_admin' where role = 'hr';
alter table public.job_team
  add constraint job_team_role_check check (role in ('recruiter', 'hiring_manager', 'general_admin'));

create or replace function app.notify_job_team() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_job record;
begin
  if new.person_id = app.current_person_id() then return new; end if;
  select id, company_id, title into v_job from public.jobs where id = new.job_id;
  perform app.notify(new.person_id, v_job.company_id, 'hiring.team',
    'You are on the hiring team: ' || v_job.title,
    'Role: ' || case new.role when 'recruiter' then 'Recruiter' when 'hiring_manager' then 'Hiring Manager'
                              when 'general_admin' then 'General Administrator' else new.role end
      || ' · you can see its candidates',
    '/hiring/jobs/' || v_job.id, 'job', v_job.id, 'hiring.team:' || v_job.id || ':' || new.person_id);
  return new;
end $$;

commit;
