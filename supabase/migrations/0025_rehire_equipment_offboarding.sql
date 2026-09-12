-- 0025_rehire_equipment_offboarding.sql
-- Equipment on the offboarding checklist (plan 033): scheduling a departure
-- adds one critical IT task per asset the person holds; taking the asset
-- back marks that task done. schedule_departure, return_asset and
-- cancel_reservation are the 0010 / 0022 bodies plus those calls.

alter table public.plan_tasks add column asset_id uuid references public.assets(id) on delete set null;
create index plan_tasks_asset_idx on public.plan_tasks (asset_id) where asset_id is not null;

create or replace function app.add_equipment_tasks(p_plan_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_plan record;
  v_n int;
begin
  select * into v_plan from public.plans where id = p_plan_id;
  if not found or v_plan.kind <> 'offboarding' then return 0; end if;
  insert into public.plan_tasks
      (plan_id, asset_id, title, description, owner_role, phase_key, due_date, critical, sort_order)
    select v_plan.id, a.id,
           format('Return %s · %s%s', a.asset_tag, t.label, coalesce(' ' || a.model, '')),
           'Equipment the person still holds; take it back and record its condition on the Equipment tab.',
           'it', 'last_day', v_plan.start_date, true, 900 + row_number() over (order by a.asset_tag)
    from public.asset_assignments aa
    join public.assets a on a.id = aa.asset_id
    join public.asset_types t on t.key = a.type_key
    where aa.person_id = v_plan.person_id and aa.returned_at is null and a.company_id = v_plan.company_id
      and not exists (select 1 from public.plan_tasks pt where pt.plan_id = v_plan.id and pt.asset_id = a.id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- The handover itself completes the open checklist task for that asset.
create or replace function app.complete_equipment_task(p_asset_id uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.plan_tasks pt
    set status = 'done', done_by = p_by, done_at = now()
    from public.plans p
    where pt.plan_id = p.id and pt.asset_id = p_asset_id and pt.status in ('open', 'blocked')
      and p.kind = 'offboarding' and p.status = 'in_progress';
end $$;

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
    update public.plans set start_date = v_last_day where id = v_plan_id;   -- the plan follows the new last day
    perform app.add_equipment_tasks(v_plan_id);   -- equipment handed out since
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

  perform app.add_equipment_tasks(v_plan_id);
  return jsonb_build_object('plan_id', v_plan_id, 'already_scheduled', false);
end $$;

create or replace function public.return_asset(p_assignment_id uuid, p_condition text default null, p_status text default 'available') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_a record;
  v_company uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_status not in ('available', 'damaged', 'lost', 'retired') then
    raise exception 'After a return an asset is available, damaged, lost or retired.';
  end if;
  select * into v_a from public.asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'Assignment not found.';
  end if;
  select company_id into v_company from public.assets where id = v_a.asset_id;
  if not (app.has_capability(v_company, 'it.assign') or app.has_capability(v_company, 'it.complete')) then
    raise exception 'Returning equipment needs it.assign or it.complete in this company.' using errcode = '42501';
  end if;
  if v_a.returned_at is not null then
    raise exception 'This assignment is already closed.';
  end if;
  if v_a.issued_at is null then
    raise exception 'This asset was reserved but never issued; cancel the reservation instead.';
  end if;
  update public.asset_assignments
    set returned_at = now(), return_condition = nullif(trim(coalesce(p_condition, '')), '')
    where id = p_assignment_id;
  update public.assets set condition = coalesce(nullif(trim(coalesce(p_condition, '')), ''), condition) where id = v_a.asset_id;
  perform app.set_asset_status(v_a.asset_id, p_status);
  perform app.complete_equipment_task(v_a.asset_id, v_me);
  return jsonb_build_object('status', p_status);
end $$;

create or replace function public.cancel_reservation(p_assignment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_a record;
  v_company uuid;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_a from public.asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'Assignment not found.';
  end if;
  select company_id into v_company from public.assets where id = v_a.asset_id;
  if not app.has_capability(v_company, 'it.assign') then
    raise exception 'Cancelling a reservation needs it.assign in this company.' using errcode = '42501';
  end if;
  if v_a.returned_at is not null or v_a.issued_at is not null then
    raise exception 'Only an open reservation can be cancelled.';
  end if;
  delete from public.asset_assignments where id = p_assignment_id;
  perform app.set_asset_status(v_a.asset_id, 'available');
  perform app.complete_equipment_task(v_a.asset_id, app.current_person_id());
  return jsonb_build_object('status', 'available');
end $$;
