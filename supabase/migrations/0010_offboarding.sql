-- 0010_offboarding.sql
-- Departures as a workflow, not a delete (blueprint §7 / core plan §7):
-- scheduling captures dates and a restricted reason and launches a task plan;
-- it does NOT deactivate the person. Becoming Former is a separate, explicit
-- act that may legitimately happen while equipment is still outstanding.
--
-- New lifecycle phases are seeded here rather than hardcoded: plan_phases is a
-- lookup table, so extending the vocabulary is an INSERT (design principle 1).

insert into public.plan_phases (key, label, sort_order) values
  ('before_last_day','Before the last day',50),
  ('last_day','Last working day',60),
  ('after_departure','After departure',70)
on conflict (key) do nothing;

-- Shared default offboarding template (company overrides can be added later
-- as rows with their own company_id — no migration needed).
with t as (
  insert into public.task_templates (company_id, kind, name)
  values (null, 'offboarding', 'Standard offboarding')
  on conflict (company_id, kind, name) do nothing
  returning id
)
insert into public.template_tasks
  (template_id, title, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order)
select t.id, v.* from t, (values
  ('Handover documented and accepted', 'manager', 'before_last_day', -5, true,  false, 10),
  ('Exit conversation held',           'hr',      'before_last_day', -2, false, false, 20),
  ('Equipment returned',               'it',      'last_day',         0, true,  false, 30),
  ('Accounts and access removed',      'it',      'last_day',         0, true,  false, 40),
  ('Final documents issued',           'hr',      'after_departure',  3, false, false, 50)
) as v(title, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order);

-- ------------------------------------------------------- schedule_departure
-- One transaction: dates on the employment period, the restricted reason in
-- its own table, and exactly one offboarding plan with dated tasks. Retrying
-- returns the existing plan instead of creating a second one.
create or replace function public.schedule_departure(
  p_employment_period_id uuid,
  p_end_date date,
  p_last_working_date date default null,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period record;
  v_plan_id uuid;
  v_template_id uuid;
  v_last_day date;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  select * into v_period from public.employment_periods
    where id = p_employment_period_id for update;
  if not found then
    raise exception 'Employment period not found.';
  end if;

  if not app.has_capability(v_period.company_id, 'departure.start') then
    raise exception 'Scheduling a departure requires departure.start in this company.'
      using errcode = '42501';
  end if;
  if p_end_date is null then
    raise exception 'Choose an employment end date.';
  end if;
  if p_end_date < v_period.start_date then
    raise exception 'The end date cannot be before the start date.';
  end if;

  v_last_day := coalesce(p_last_working_date, p_end_date);
  if v_last_day > p_end_date then
    raise exception 'The last working date cannot be after the employment end date.';
  end if;

  -- Idempotent: one open offboarding plan per employment period.
  select id into v_plan_id from public.plans
    where employment_period_id = p_employment_period_id
      and kind = 'offboarding' and status = 'in_progress'
    limit 1;
  if v_plan_id is not null then
    update public.employment_periods
      set end_date = p_end_date, last_working_date = v_last_day
      where id = p_employment_period_id;
    return jsonb_build_object('plan_id', v_plan_id, 'already_scheduled', true);
  end if;

  -- Scheduling records dates; it never deactivates the person. Status flips
  -- to 'former' only through complete_departure.
  update public.employment_periods
    set end_date = p_end_date, last_working_date = v_last_day
    where id = p_employment_period_id;

  if p_reason is not null and length(trim(p_reason)) > 0 then
    insert into public.employment_departure_details
        (employment_period_id, reason, recorded_by)
      values (p_employment_period_id, trim(p_reason), app.current_person_id())
      on conflict (employment_period_id) do update
        set reason = excluded.reason,
            recorded_by = excluded.recorded_by,
            recorded_at = now();
  end if;

  select id into v_template_id from public.task_templates
    where kind = 'offboarding' and active
      and (company_id = v_period.company_id or company_id is null)
    order by company_id nulls last, created_at
    limit 1;

  insert into public.plans
      (kind, person_id, company_id, employment_period_id, template_id,
       hr_owner_id, start_date)
    values ('offboarding', v_period.person_id, v_period.company_id,
            p_employment_period_id, v_template_id, app.current_person_id(),
            v_last_day)
    returning id into v_plan_id;

  if v_template_id is not null then
    insert into public.plan_tasks
        (plan_id, template_task_id, title, description, owner_role, phase_key,
         due_date, critical, requires_evidence, sort_order)
      select v_plan_id, tt.id, tt.title, tt.description, tt.default_owner_role,
             tt.phase_key, v_last_day + tt.due_offset_days, tt.critical,
             tt.requires_evidence, tt.sort_order
      from public.template_tasks tt
      where tt.template_id = v_template_id;
  end if;

  return jsonb_build_object('plan_id', v_plan_id, 'already_scheduled', false);
end $$;

-- ------------------------------------------------------- complete_departure
-- The explicit act of becoming Former. Deliberately allowed while tasks are
-- still open (equipment can outlive the employment) — the count comes back so
-- the UI can say what is still outstanding.
create or replace function public.complete_departure(
  p_employment_period_id uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period record;
  v_plan_id uuid;
  v_open int := 0;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  select * into v_period from public.employment_periods
    where id = p_employment_period_id for update;
  if not found then
    raise exception 'Employment period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'departure.start') then
    raise exception 'Completing a departure requires departure.start in this company.'
      using errcode = '42501';
  end if;
  if v_period.end_date is null then
    raise exception 'Schedule the departure first: there is no employment end date.';
  end if;

  update public.employment_periods
    set status = 'former'
    where id = p_employment_period_id;

  select id into v_plan_id from public.plans
    where employment_period_id = p_employment_period_id
      and kind = 'offboarding' and status = 'in_progress'
    limit 1;
  if v_plan_id is not null then
    select count(*) into v_open from public.plan_tasks
      where plan_id = v_plan_id and status not in ('done','skipped');
    update public.plans
      set status = 'completed', completed_at = now()
      where id = v_plan_id;
  end if;

  return jsonb_build_object('plan_id', v_plan_id, 'open_tasks', v_open);
end $$;

revoke all on function public.schedule_departure(uuid, date, date, text) from public, anon;
revoke all on function public.complete_departure(uuid) from public, anon;
grant execute on function public.schedule_departure(uuid, date, date, text) to authenticated, service_role;
grant execute on function public.complete_departure(uuid) to authenticated, service_role;
