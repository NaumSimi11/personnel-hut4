-- 0009_confirm_hire.sql
-- The candidate→employee handoff as ONE atomic, idempotent operation
-- (blueprint §4 "Hire" row and §8 acceptance: "Hiring confirmation is retried
-- after a timeout; exactly one employee and onboarding plan are created").
-- SECURITY DEFINER with explicit checks: RLS gates who touches tables, this
-- gates the multi-table transition. The unique applications.employment_period_id
-- constraint backs the idempotency structurally.

create or replace function public.confirm_hire(
  p_application_id uuid,
  p_full_name text,
  p_job_title text,
  p_start_date date,
  p_manager_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_app record;
  v_job record;
  v_candidate record;
  v_person_id uuid;
  v_period_id uuid;
  v_plan_id uuid;
  v_template_id uuid;
  v_status text;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then
    raise exception 'Enter the new employee''s full name.';
  end if;
  if length(trim(coalesce(p_job_title, ''))) < 2 then
    raise exception 'Enter the position title.';
  end if;
  if p_start_date is null then
    raise exception 'Choose a start date.';
  end if;

  select * into v_app from public.applications where id = p_application_id for update;
  if not found then
    raise exception 'Application not found.';
  end if;
  select * into v_job from public.jobs where id = v_app.job_id;

  if not app.has_capability(v_job.company_id, 'employment.edit') then
    raise exception 'Confirming a hire requires employment.edit in this company.'
      using errcode = '42501';
  end if;

  -- Idempotent: confirming an already-confirmed hire returns the first result.
  if v_app.employment_period_id is not null then
    select person_id into v_person_id
      from public.employment_periods where id = v_app.employment_period_id;
    select id into v_plan_id from public.plans
      where employment_period_id = v_app.employment_period_id and kind = 'onboarding'
      limit 1;
    return jsonb_build_object(
      'person_id', v_person_id,
      'employment_period_id', v_app.employment_period_id,
      'plan_id', v_plan_id,
      'already_hired', true);
  end if;

  if v_app.stage_key <> 'offer' then
    raise exception 'Only applications at the offer stage can be confirmed as hires.';
  end if;

  select * into v_candidate from public.candidates where id = v_app.candidate_id;

  -- Same invariant as inviting: attach to an existing person matched by work
  -- email (rehires), never insert a duplicate identity.
  if v_candidate.email is not null then
    select id into v_person_id from public.people
      where work_email = v_candidate.email limit 1;
  end if;
  if v_person_id is null then
    insert into public.people (full_name, work_email)
      values (trim(p_full_name), v_candidate.email)
      returning id into v_person_id;
  end if;

  v_status := case when p_start_date > current_date then 'pre_start' else 'active' end;
  begin
    insert into public.employment_periods
        (person_id, company_id, job_title, status, start_date, manager_id)
      values (v_person_id, v_job.company_id, trim(p_job_title), v_status,
              p_start_date, p_manager_id)
      returning id into v_period_id;
  exception when exclusion_violation then
    raise exception 'This person already has an employment period covering that date — end it first.';
  end;

  update public.applications
    set employment_period_id = v_period_id, stage_key = 'hired'
    where id = p_application_id;

  insert into public.application_events
      (application_id, kind, from_stage_key, to_stage_key, actor_id, body)
    values (p_application_id, 'stage_change', v_app.stage_key, 'hired',
            app.current_person_id(), 'Hire confirmed');

  -- Assign the standard onboarding plan (shared template; company-specific
  -- overrides pick the company template first when one exists).
  select id into v_template_id from public.task_templates
    where kind = 'onboarding' and active
      and (company_id = v_job.company_id or company_id is null)
    order by company_id nulls last, created_at
    limit 1;
  if v_template_id is not null then
    insert into public.plans
        (kind, person_id, company_id, employment_period_id, template_id,
         hr_owner_id, start_date)
      values ('onboarding', v_person_id, v_job.company_id, v_period_id,
              v_template_id, app.current_person_id(), p_start_date)
      returning id into v_plan_id;
    insert into public.plan_tasks
        (plan_id, template_task_id, title, description, owner_role, phase_key,
         due_date, critical, requires_evidence, sort_order)
      select v_plan_id, tt.id, tt.title, tt.description, tt.default_owner_role,
             tt.phase_key, p_start_date + tt.due_offset_days, tt.critical,
             tt.requires_evidence, tt.sort_order
      from public.template_tasks tt
      where tt.template_id = v_template_id;
  end if;

  return jsonb_build_object(
    'person_id', v_person_id,
    'employment_period_id', v_period_id,
    'plan_id', v_plan_id,
    'already_hired', false);
end $$;

revoke all on function public.confirm_hire(uuid, text, text, date, uuid) from public, anon;
grant execute on function public.confirm_hire(uuid, text, text, date, uuid) to authenticated, service_role;
