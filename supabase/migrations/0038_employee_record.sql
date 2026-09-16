-- 0038_employee_record.sql
-- Plan 046: the employee record entered once, edited where it is shown, and
-- the checklist starting by itself.
--   1. person_private_details gains national_id and bank_account (what the
--      accountant needs, plan 048) and is audited by field name only — which
--      columns changed, never their values. 0005 left it unaudited for that
--      very reason; a row saying "bank_account changed by X at T" is the
--      minimum the hand-over trail needs.
--   2. departments and locations may be added and edited by employment.edit
--      holders in that company; holding-wide rows (no company) stay admin-only.
--   3. create_employee(jsonb): person, first employment, private details, a
--      pay proposal and the onboarding checklist in one transaction. With an
--      application id it is the hire; confirm_hire becomes a wrapper over it,
--      old signature and messages kept.
--   4. correct_employment also corrects department, location and manager.
--   5. import_people takes the same columns and writes every row through
--      create_employee, so one rule set decides both routes.

-- ------------------------------------------------------- 1. private details
alter table public.person_private_details
  add column national_id text
    check (national_id is null or length(national_id) between 4 and 32),
  add column bank_account jsonb
    check (bank_account is null or jsonb_typeof(bank_account) = 'object');

comment on column public.person_private_details.national_id is
  'Full national identification number (ЕМБГ or equivalent). personal.view only; never audited, never exported except through a recorded hand-over send (plan 048).';
comment on column public.person_private_details.bank_account is
  '{"bank": "...", "account_number": "..."} — transaction account or IBAN for payroll. personal.view only.';

-- The hint (last four digits) follows the full value, so directory-level
-- readers keep the same clue they had.
create or replace function app.private_details_hint() returns trigger
language plpgsql as $$
begin
  new.national_id := nullif(btrim(new.national_id), '');
  if new.national_id is not null then
    new.national_id_hint := right(new.national_id, 4);
  end if;
  return new;
end $$;
create trigger hint before insert or update on public.person_private_details
  for each row execute function app.private_details_hint();

-- Audit by field name only: the log says which columns changed and who did
-- it, never a value. tg_argv[0] names the id column (default 'id').
create or replace function app.audit_fields_only() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_id_col text := coalesce(tg_argv[0], 'id');
  v_rec jsonb := to_jsonb(coalesce(new, old));
  v_fields text[];
  v_summary jsonb;
begin
  if tg_op = 'UPDATE' then
    select coalesce(array_agg(e.key order by e.key), '{}') into v_fields
      from jsonb_each(to_jsonb(new)) e
      where e.key not in (v_id_col, 'updated_at')
        and e.value is distinct from (to_jsonb(old) -> e.key);
  else
    select coalesce(array_agg(e.key order by e.key), '{}') into v_fields
      from jsonb_each(v_rec) e
      where e.key not in (v_id_col, 'updated_at', 'custom')
        and jsonb_typeof(e.value) <> 'null'
        and e.value <> '[]'::jsonb;
  end if;
  v_summary := jsonb_build_object('fields', to_jsonb(v_fields));
  insert into public.activity_log
    (company_id, actor_person_id, actor_user_id, entity_type, entity_id, action, before, after)
  values (
    null,
    app.current_person_id(),
    auth.uid(),
    tg_table_name,
    v_rec ->> v_id_col,
    tg_op,
    case when tg_op = 'DELETE' then v_summary end,
    case when tg_op <> 'DELETE' then v_summary end
  );
  return coalesce(new, old);
end $$;

create trigger audit after insert or update or delete on public.person_private_details
  for each row execute function app.audit_fields_only('person_id');

-- ------------------------------------------------------- 2. structure for HR
-- Reference rows of one company are HR's to keep; the shared holding rows
-- (company_id null) remain the admins'. Policies are permissive, so these
-- add to admin_write from 0006 rather than replacing it.
create policy hr_insert on public.departments for insert to authenticated
  with check (company_id is not null and app.has_capability(company_id, 'employment.edit'));
create policy hr_update on public.departments for update to authenticated
  using (company_id is not null and app.has_capability(company_id, 'employment.edit'))
  with check (company_id is not null and app.has_capability(company_id, 'employment.edit'));
create policy hr_insert on public.locations for insert to authenticated
  with check (company_id is not null and app.has_capability(company_id, 'employment.edit'));
create policy hr_update on public.locations for update to authenticated
  using (company_id is not null and app.has_capability(company_id, 'employment.edit'))
  with check (company_id is not null and app.has_capability(company_id, 'employment.edit'));

-- --------------------------------------------------- 3. the onboarding plan
-- Lifted out of confirm_hire (0009): the company's template first, else the
-- holding's; idempotent per employment period.
create or replace function app.start_onboarding_plan(
  p_person_id uuid, p_company_id uuid, p_period_id uuid, p_start_date date
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_template_id uuid;
  v_plan_id uuid;
begin
  select id into v_plan_id from public.plans
    where employment_period_id = p_period_id and kind = 'onboarding'
    limit 1;
  if v_plan_id is not null then
    return v_plan_id;
  end if;
  select id into v_template_id from public.task_templates
    where kind = 'onboarding' and active
      and (company_id = p_company_id or company_id is null)
    order by company_id nulls last, created_at
    limit 1;
  if v_template_id is null then
    return null;
  end if;
  insert into public.plans
      (kind, person_id, company_id, employment_period_id, template_id, hr_owner_id, start_date)
    values ('onboarding', p_person_id, p_company_id, p_period_id, v_template_id,
            app.current_person_id(), p_start_date)
    returning id into v_plan_id;
  insert into public.plan_tasks
      (plan_id, template_task_id, title, description, owner_role, phase_key,
       due_date, critical, requires_evidence, sort_order)
    select v_plan_id, tt.id, tt.title, tt.description, tt.default_owner_role,
           tt.phase_key, p_start_date + tt.due_offset_days, tt.critical,
           tt.requires_evidence, tt.sort_order
    from public.template_tasks tt
    where tt.template_id = v_template_id;
  return v_plan_id;
end $$;

-- True when any value in the object is more than whitespace.
create or replace function app.jsonb_has_values(p jsonb) returns boolean
language sql immutable as $$
  select p is not null and jsonb_typeof(p) = 'object' and exists (
    select 1 from jsonb_each_text(p) e where nullif(btrim(e.value), '') is not null)
$$;

/**
 * One employee, one call. Keys of p:
 *   full_name*, preferred_name, work_email, personal_email, phone,
 *   company_id* (ignored with application_id — the job decides),
 *   job_title*, department_id, location_id, employment_type_key, manager_id,
 *   start_date*, start_onboarding (default true), application_id,
 *   private: { birth_date, address_line, national_id, bank_name,
 *              bank_account_number, emergency_name, emergency_relationship,
 *              emergency_phone, notes }            — needs personal.view
 *   pay:     { amount, currency, pay_basis_key, note } — needs salary.propose;
 *            effective from the start date, saved as a proposal.
 * Returns {person_id, employment_period_id, plan_id, compensation_record_id,
 * already_hired}. Every refusal happens before the first write.
 */
create or replace function public.create_employee(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_app record;
  v_job record;
  v_candidate record;
  v_application uuid;
  v_company uuid;
  v_name text;
  v_preferred text;
  v_work_email text;
  v_personal_email text;
  v_phone text;
  v_title text;
  v_start date;
  v_type text;
  v_dept uuid;
  v_loc uuid;
  v_manager uuid;
  v_private jsonb := p -> 'private';
  v_pay jsonb := p -> 'pay';
  v_private_given boolean;
  v_pay_given boolean;
  v_start_plan boolean;
  v_person uuid;
  v_period uuid;
  v_plan uuid;
  v_comp uuid;
  v_status text;
  v_checks jsonb := '{}'::jsonb;
  v_shape public.employment_periods;
  v_birth date;
  v_contacts jsonb := '[]'::jsonb;
  v_bank jsonb;
  v_address jsonb;
  v_amount numeric;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Send the employee as an object.' using errcode = '22023';
  end if;

  v_name := btrim(coalesce(p ->> 'full_name', ''));
  v_preferred := nullif(btrim(coalesce(p ->> 'preferred_name', '')), '');
  v_work_email := lower(nullif(btrim(coalesce(p ->> 'work_email', '')), ''));
  v_personal_email := lower(nullif(btrim(coalesce(p ->> 'personal_email', '')), ''));
  v_phone := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_title := btrim(coalesce(p ->> 'job_title', ''));
  v_type := nullif(btrim(coalesce(p ->> 'employment_type_key', '')), '');
  v_dept := nullif(p ->> 'department_id', '')::uuid;
  v_loc := nullif(p ->> 'location_id', '')::uuid;
  v_manager := nullif(p ->> 'manager_id', '')::uuid;
  v_application := nullif(p ->> 'application_id', '')::uuid;
  v_start_plan := coalesce((p ->> 'start_onboarding')::boolean, true);
  v_private_given := app.jsonb_has_values(v_private);
  v_pay_given := v_pay is not null and jsonb_typeof(v_pay) = 'object'
                 and nullif(btrim(coalesce(v_pay ->> 'amount', '')), '') is not null;

  if length(v_name) < 2 then
    raise exception 'Enter the full name.' using errcode = '22023';
  end if;
  if length(v_title) < 2 then
    raise exception 'Enter the job title.' using errcode = '22023';
  end if;
  begin
    v_start := (p ->> 'start_date')::date;
  exception when others then
    v_start := null;
  end;
  if v_start is null then
    raise exception 'Choose a start date.' using errcode = '22023';
  end if;
  if v_work_email is not null and v_work_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'The work email is not an address.' using errcode = '22023';
  end if;
  if v_personal_email is not null and v_personal_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'The personal email is not an address.' using errcode = '22023';
  end if;

  -- From an application the job decides the company and the candidate's
  -- email is the identity (0009's rules, unchanged).
  if v_application is not null then
    select * into v_app from public.applications where id = v_application for update;
    if not found then
      raise exception 'Application not found.' using errcode = 'P0002';
    end if;
    select * into v_job from public.jobs where id = v_app.job_id;
    v_company := v_job.company_id;
    if not app.has_capability(v_company, 'employment.edit') then
      raise exception 'Confirming a hire requires employment.edit in this company.'
        using errcode = '42501';
    end if;
    if v_app.employment_period_id is not null then
      select person_id into v_person from public.employment_periods
        where id = v_app.employment_period_id;
      select id into v_plan from public.plans
        where employment_period_id = v_app.employment_period_id and kind = 'onboarding'
        limit 1;
      return jsonb_build_object(
        'person_id', v_person,
        'employment_period_id', v_app.employment_period_id,
        'plan_id', v_plan,
        'compensation_record_id', null,
        'already_hired', true);
    end if;
    if v_app.stage_key <> 'offer' then
      raise exception 'Only applications at the offer stage can be confirmed as hires.';
    end if;
    select * into v_candidate from public.candidates where id = v_app.candidate_id;
  else
    v_company := nullif(p ->> 'company_id', '')::uuid;
    if v_company is null then
      raise exception 'Choose the employing company.' using errcode = '22023';
    end if;
    if not app.has_capability(v_company, 'employment.edit') then
      raise exception 'Adding an employee requires employment.edit in this company.'
        using errcode = '42501';
    end if;
  end if;
  if not exists (select 1 from public.companies where id = v_company and archived_at is null) then
    raise exception 'That company is archived.' using errcode = '22023';
  end if;

  -- The sensitive parts are refused before anything is written.
  if v_private_given and not app.has_capability(v_company, 'personal.view') then
    raise exception 'Personal details need personal.view in this company.'
      using errcode = '42501';
  end if;
  if v_pay_given and not app.has_capability(v_company, 'salary.propose') then
    raise exception 'Proposing compensation requires salary.propose in this company.'
      using errcode = '42501';
  end if;
  if v_private_given then
    begin
      v_birth := nullif(v_private ->> 'birth_date', '')::date;
    exception when others then
      raise exception 'The birth date is not a date (use YYYY-MM-DD).' using errcode = '22023';
    end;
    if v_birth is not null and v_birth > current_date then
      raise exception 'The birth date cannot be in the future.' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(v_private ->> 'national_id', '')), '') is not null
       and length(btrim(v_private ->> 'national_id')) not between 4 and 32 then
      raise exception 'The national ID must be between 4 and 32 characters.' using errcode = '22023';
    end if;
  end if;
  if v_pay_given then
    begin
      v_amount := (v_pay ->> 'amount')::numeric;
    exception when others then
      raise exception 'The pay amount is not a number.' using errcode = '22023';
    end;
  end if;

  -- Identity: a plain add never merges into an existing record; a hire
  -- attaches to the person the candidate's email already belongs to (rehire).
  if v_application is not null then
    if v_candidate.email is not null then
      select id into v_person from public.people
        where work_email = v_candidate.email or personal_email = v_candidate.email
        order by created_at
        limit 1;
    end if;
    if v_work_email is null and v_personal_email is null then
      v_work_email := lower(v_candidate.email::text);
    end if;
  elsif v_work_email is not null
        and exists (select 1 from public.people where lower(work_email::text) = v_work_email) then
    raise exception 'A person with this work email already exists — open their record and add the employment there.'
      using errcode = '23505';
  end if;

  if v_person is null then
    insert into public.people (full_name, preferred_name, work_email, personal_email, phone)
      values (v_name, v_preferred, v_work_email, v_personal_email, v_phone)
      returning id into v_person;
  else
    update public.people
       set preferred_name = coalesce(v_preferred, preferred_name),
           personal_email = coalesce(v_personal_email, personal_email),
           phone = coalesce(v_phone, phone)
     where id = v_person;
  end if;

  -- The structure checks 0018 already keeps for changes, on the period to be.
  v_shape.person_id := v_person;
  v_shape.company_id := v_company;
  if v_dept is not null then v_checks := v_checks || jsonb_build_object('department_id', v_dept); end if;
  if v_loc is not null then v_checks := v_checks || jsonb_build_object('location_id', v_loc); end if;
  if v_manager is not null then v_checks := v_checks || jsonb_build_object('manager_id', v_manager); end if;
  if v_type is not null then v_checks := v_checks || jsonb_build_object('employment_type_key', v_type); end if;
  if v_checks <> '{}'::jsonb then
    perform app.validate_employment_change(v_shape, v_checks);
  end if;

  v_status := case when v_start > current_date then 'pre_start' else 'active' end;
  begin
    insert into public.employment_periods
        (person_id, company_id, job_title, department_id, location_id,
         employment_type_key, manager_id, status, start_date)
      values (v_person, v_company, v_title, v_dept, v_loc, v_type, v_manager, v_status, v_start)
      returning id into v_period;
  exception when exclusion_violation then
    raise exception 'This person already has an employment period covering that date — end it first.'
      using errcode = '23P01';
  end;

  if v_application is not null then
    update public.applications
      set employment_period_id = v_period, stage_key = 'hired'
      where id = v_application;
    insert into public.application_events
        (application_id, kind, from_stage_key, to_stage_key, actor_id, body)
      values (v_application, 'stage_change', v_app.stage_key, 'hired', v_me, 'Hire confirmed');
  end if;

  if v_private_given then
    if nullif(btrim(coalesce(v_private ->> 'emergency_name', '')), '') is not null
       or nullif(btrim(coalesce(v_private ->> 'emergency_phone', '')), '') is not null then
      v_contacts := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'name', nullif(btrim(coalesce(v_private ->> 'emergency_name', '')), ''),
        'relationship', nullif(btrim(coalesce(v_private ->> 'emergency_relationship', '')), ''),
        'phone', nullif(btrim(coalesce(v_private ->> 'emergency_phone', '')), ''))));
    end if;
    if nullif(btrim(coalesce(v_private ->> 'bank_name', '')), '') is not null
       or nullif(btrim(coalesce(v_private ->> 'bank_account_number', '')), '') is not null then
      v_bank := jsonb_strip_nulls(jsonb_build_object(
        'bank', nullif(btrim(coalesce(v_private ->> 'bank_name', '')), ''),
        'account_number', nullif(btrim(coalesce(v_private ->> 'bank_account_number', '')), '')));
    end if;
    if nullif(btrim(coalesce(v_private ->> 'address_line', '')), '') is not null then
      v_address := jsonb_build_object('line', btrim(v_private ->> 'address_line'));
    end if;
    insert into public.person_private_details
        (person_id, birth_date, address, national_id, bank_account, emergency_contacts, notes)
      values (v_person, v_birth, v_address,
              nullif(btrim(coalesce(v_private ->> 'national_id', '')), ''),
              v_bank, v_contacts,
              nullif(btrim(coalesce(v_private ->> 'notes', '')), ''))
      on conflict (person_id) do update set
        birth_date = coalesce(excluded.birth_date, person_private_details.birth_date),
        address = coalesce(excluded.address, person_private_details.address),
        national_id = coalesce(excluded.national_id, person_private_details.national_id),
        bank_account = coalesce(excluded.bank_account, person_private_details.bank_account),
        emergency_contacts = case when excluded.emergency_contacts <> '[]'::jsonb
                                  then excluded.emergency_contacts
                                  else person_private_details.emergency_contacts end,
        notes = coalesce(excluded.notes, person_private_details.notes);
  end if;

  if v_pay_given then
    v_comp := (public.propose_compensation(
      v_period, v_amount, v_pay ->> 'currency', v_pay ->> 'pay_basis_key', v_start,
      v_pay ->> 'note') ->> 'record_id')::uuid;
  end if;

  if v_start_plan then
    v_plan := app.start_onboarding_plan(v_person, v_company, v_period, v_start);
  end if;

  return jsonb_build_object(
    'person_id', v_person,
    'employment_period_id', v_period,
    'plan_id', v_plan,
    'compensation_record_id', v_comp,
    'already_hired', false);
end $$;

revoke all on function public.create_employee(jsonb) from public, anon;
grant execute on function public.create_employee(jsonb) to authenticated, service_role;

-- confirm_hire keeps its signature and answers for every caller; the work
-- is create_employee's.
create or replace function public.confirm_hire(
  p_application_id uuid,
  p_full_name text,
  p_job_title text,
  p_start_date date,
  p_manager_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
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
  return public.create_employee(jsonb_strip_nulls(jsonb_build_object(
    'application_id', p_application_id,
    'full_name', p_full_name,
    'job_title', p_job_title,
    'start_date', p_start_date,
    'manager_id', p_manager_id)));
end $$;

-- ------------------------------------------- 4. correcting the whole period
alter table public.employment_corrections
  add column old_department_id uuid references public.departments(id),
  add column new_department_id uuid references public.departments(id),
  add column old_location_id uuid references public.locations(id),
  add column new_location_id uuid references public.locations(id),
  add column old_manager_id uuid references public.people(id),
  add column new_manager_id uuid references public.people(id);

drop function public.correct_employment(uuid, date, text, text, text);

/**
 * As 0037, plus p_fields for department_id, location_id and manager_id: a key
 * present with null clears the value, an absent key keeps it. The same
 * validator as a scheduled change decides whether the department belongs
 * here and whether the manager would loop.
 */
create or replace function public.correct_employment(
  p_period_id uuid,
  p_start_date date,
  p_job_title text default null,
  p_employment_type_key text default null,
  p_reason text default null,
  p_fields jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_p public.employment_periods;
  v_title text;
  v_type text;
  v_status text;
  v_dept uuid;
  v_loc uuid;
  v_manager uuid;
  v_key text;
  v_checks jsonb := '{}'::jsonb;
begin
  select * into v_p from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'That employment no longer exists.' using errcode = 'P0002';
  end if;
  if not app.has_capability(v_p.company_id, 'employment.edit') then
    raise exception 'Correcting an employment requires employment.edit'
      using errcode = '42501';
  end if;
  if p_start_date is null then
    raise exception 'A start date is required.' using errcode = '22023';
  end if;
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'Send the fields as an object.' using errcode = '22023';
  end if;
  for v_key in select jsonb_object_keys(p_fields) loop
    if v_key not in ('department_id', 'location_id', 'manager_id') then
      raise exception 'Unknown field: %', v_key using errcode = '22023';
    end if;
  end loop;

  v_title := coalesce(nullif(btrim(p_job_title), ''), v_p.job_title);
  v_type := coalesce(nullif(btrim(p_employment_type_key), ''), v_p.employment_type_key);
  if v_type is not null and not exists (select 1 from public.employment_types where key = v_type) then
    raise exception 'Unknown employment type: %', v_type using errcode = '22023';
  end if;
  v_dept := case when p_fields ? 'department_id' then nullif(p_fields ->> 'department_id', '')::uuid else v_p.department_id end;
  v_loc := case when p_fields ? 'location_id' then nullif(p_fields ->> 'location_id', '')::uuid else v_p.location_id end;
  v_manager := case when p_fields ? 'manager_id' then nullif(p_fields ->> 'manager_id', '')::uuid else v_p.manager_id end;
  if p_fields ? 'department_id' and v_dept is not null then v_checks := v_checks || jsonb_build_object('department_id', v_dept); end if;
  if p_fields ? 'location_id' and v_loc is not null then v_checks := v_checks || jsonb_build_object('location_id', v_loc); end if;
  if p_fields ? 'manager_id' and v_manager is not null then v_checks := v_checks || jsonb_build_object('manager_id', v_manager); end if;
  if v_checks <> '{}'::jsonb then
    perform app.validate_employment_change(v_p, v_checks);
  end if;

  if v_p.end_date is not null and p_start_date > v_p.end_date then
    raise exception 'The start date cannot be after the end date (%).', v_p.end_date
      using errcode = '22023';
  end if;
  if v_p.last_working_date is not null and p_start_date > v_p.last_working_date then
    raise exception 'The start date cannot be after the last working date (%).', v_p.last_working_date
      using errcode = '22023';
  end if;
  if exists (
    select 1 from public.employment_periods o
    where o.person_id = v_p.person_id
      and o.id <> v_p.id
      and o.status <> 'draft'
      and daterange(o.start_date, coalesce(o.end_date, 'infinity'::date), '[]')
          && daterange(p_start_date, coalesce(v_p.end_date, 'infinity'::date), '[]')
  ) then
    raise exception 'That start date overlaps another employment this person holds.'
      using errcode = '23P01';
  end if;

  v_status := case
    when v_p.status in ('active', 'pre_start')
      then case when p_start_date > current_date then 'pre_start' else 'active' end
    else v_p.status
  end;

  insert into public.employment_corrections (
    period_id, company_id, person_id,
    old_start_date, old_job_title, old_employment_type_key,
    new_start_date, new_job_title, new_employment_type_key,
    old_department_id, new_department_id,
    old_location_id, new_location_id,
    old_manager_id, new_manager_id,
    reason, corrected_by
  ) values (
    v_p.id, v_p.company_id, v_p.person_id,
    v_p.start_date, v_p.job_title, v_p.employment_type_key,
    p_start_date, v_title, v_type,
    v_p.department_id, v_dept,
    v_p.location_id, v_loc,
    v_p.manager_id, v_manager,
    nullif(btrim(p_reason), ''), v_me
  );

  update public.employment_periods
     set start_date = p_start_date,
         job_title = v_title,
         employment_type_key = v_type,
         department_id = v_dept,
         location_id = v_loc,
         manager_id = v_manager,
         status = v_status
   where id = p_period_id;

  return jsonb_build_object(
    'id', v_p.id,
    'start_date', p_start_date,
    'job_title', v_title,
    'employment_type_key', v_type,
    'department_id', v_dept,
    'location_id', v_loc,
    'manager_id', v_manager,
    'status', v_status
  );
end $$;

revoke all on function public.correct_employment(uuid, date, text, text, text, jsonb) from public;
grant execute on function public.correct_employment(uuid, date, text, text, text, jsonb) to authenticated;

-- ------------------------------------------------ 5. import, same columns
-- Validation as 0024 plus the private and salary columns; the write goes
-- through create_employee row by row, so the two routes share one rule set.
-- A checklist starts for people whose start date is today or later — a
-- backfill of people long employed gets none.
create or replace function public.import_people(p_company_id uuid, p_rows jsonb, p_commit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_row jsonb;
  v_i int := 0;
  v_verdicts jsonb := '[]'::jsonb;
  v_problems text[];
  v_email text;
  v_emails text[] := '{}';
  v_name text;
  v_title text;
  v_start date;
  v_type text;
  v_dept uuid;
  v_loc uuid;
  v_manager_email text;
  v_ready int := 0;
  v_refused int := 0;
  v_ids jsonb := '{}'::jsonb;    -- email → person id, for manager links
  v_person uuid;
  v_manager uuid;
  v_private_cols text[] := array['personal_email', 'birth_date', 'address', 'national_id', 'bank_name',
    'bank_account_number', 'emergency_contact_name', 'emergency_contact_relationship', 'emergency_contact_phone'];
  v_has_private boolean := false;
  v_has_salary boolean := false;
  v_col text;
  v_result jsonb;
  v_private jsonb;
  v_pay jsonb;
  v_amount numeric;
  v_birth date;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'employment.edit') then
    raise exception 'Importing people needs employment.edit in this company.' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Send the rows as a list.';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'The file has no rows.';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Import at most 500 people at a time.';
  end if;

  -- A private or salary column anywhere in the file needs the capability
  -- before a single row is judged: a capability gap is not a row problem.
  for v_row in select * from jsonb_array_elements(p_rows) loop
    foreach v_col in array v_private_cols loop
      if v_col <> 'personal_email' and nullif(btrim(coalesce(v_row ->> v_col, '')), '') is not null then
        v_has_private := true;
      end if;
    end loop;
    if nullif(btrim(coalesce(v_row ->> 'salary_amount', '')), '') is not null then
      v_has_salary := true;
    end if;
  end loop;
  if v_has_private and not app.has_capability(p_company_id, 'personal.view') then
    raise exception 'The file carries personal details; importing them needs personal.view in this company.'
      using errcode = '42501';
  end if;
  if v_has_salary and not app.has_capability(p_company_id, 'salary.propose') then
    raise exception 'The file carries salaries; importing them needs salary.propose in this company.'
      using errcode = '42501';
  end if;

  -- ------------------------------------------------------------ validate
  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_i := v_i + 1;
    v_problems := '{}';
    v_name := trim(coalesce(v_row->>'full_name', ''));
    v_email := lower(trim(coalesce(v_row->>'work_email', '')));
    v_title := trim(coalesce(v_row->>'job_title', ''));
    v_type := nullif(trim(coalesce(v_row->>'employment_type_key', '')), '');
    v_manager_email := lower(trim(coalesce(v_row->>'manager_email', '')));
    v_dept := null;
    v_loc := null;

    if length(v_name) < 2 then v_problems := array_append(v_problems, 'Full name is missing'); end if;
    if v_email = '' then
      v_problems := array_append(v_problems, 'Work email is missing');
    elsif v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      v_problems := array_append(v_problems, 'Work email is not an address');
    elsif v_email = any(v_emails) then
      v_problems := array_append(v_problems, 'Work email appears twice in the file');
    elsif exists (select 1 from public.people p where lower(p.work_email::text) = v_email) then
      v_problems := array_append(v_problems, 'A person with this work email already exists');
    end if;
    v_emails := v_emails || v_email;
    if nullif(trim(coalesce(v_row->>'personal_email', '')), '') is not null
       and lower(trim(v_row->>'personal_email')) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      v_problems := array_append(v_problems, 'Personal email is not an address');
    end if;
    if length(v_title) < 2 then v_problems := array_append(v_problems, 'Job title is missing'); end if;
    begin
      v_start := (v_row->>'start_date')::date;
      if v_start is null then v_problems := array_append(v_problems, 'Start date is missing'); end if;
    exception when others then
      v_start := null;
      v_problems := array_append(v_problems, 'Start date is not a date (use YYYY-MM-DD)');
    end;
    if nullif(trim(coalesce(v_row->>'birth_date', '')), '') is not null then
      begin
        v_birth := (v_row->>'birth_date')::date;
        if v_birth > current_date then v_problems := array_append(v_problems, 'Birth date is in the future'); end if;
      exception when others then
        v_problems := array_append(v_problems, 'Birth date is not a date (use YYYY-MM-DD)');
      end;
    end if;
    if nullif(trim(coalesce(v_row->>'national_id', '')), '') is not null
       and length(trim(v_row->>'national_id')) not between 4 and 32 then
      v_problems := array_append(v_problems, 'National ID must be between 4 and 32 characters');
    end if;
    if nullif(trim(coalesce(v_row->>'salary_amount', '')), '') is not null then
      begin
        v_amount := (v_row->>'salary_amount')::numeric;
        if v_amount <= 0 then v_problems := array_append(v_problems, 'Salary amount must be above zero'); end if;
      exception when others then
        v_problems := array_append(v_problems, 'Salary amount is not a number');
      end;
      if upper(trim(coalesce(v_row->>'salary_currency', ''))) !~ '^[A-Z]{3}$' then
        v_problems := array_append(v_problems, 'Salary currency must be a three-letter code like EUR or MKD');
      end if;
      if not exists (select 1 from public.pay_bases b where b.key = lower(trim(coalesce(v_row->>'salary_basis', '')))) then
        v_problems := array_append(v_problems, 'Salary basis must be one of annual, monthly, daily, hourly');
      end if;
    end if;
    if v_type is not null and not exists (select 1 from public.employment_types t where t.key = v_type and t.archived_at is null) then
      v_problems := array_append(v_problems, format('Employment type "%s" is unknown', v_type));
    end if;
    if nullif(trim(coalesce(v_row->>'department', '')), '') is not null then
      select d.id into v_dept from public.departments d
        where lower(d.name) = lower(trim(v_row->>'department')) and d.archived_at is null
          and (d.company_id = p_company_id or d.company_id is null)
        order by d.company_id nulls last limit 1;
      if v_dept is null then v_problems := array_append(v_problems, format('Department "%s" is unknown here', trim(v_row->>'department'))); end if;
    end if;
    if nullif(trim(coalesce(v_row->>'location', '')), '') is not null then
      select l.id into v_loc from public.locations l
        where lower(l.name) = lower(trim(v_row->>'location')) and l.archived_at is null
          and (l.company_id = p_company_id or l.company_id is null)
        order by l.company_id nulls last limit 1;
      if v_loc is null then v_problems := array_append(v_problems, format('Location "%s" is unknown here', trim(v_row->>'location'))); end if;
    end if;
    if v_manager_email <> '' then
      if v_manager_email = v_email then
        v_problems := array_append(v_problems, 'A person cannot be their own manager');
      elsif not exists (select 1 from jsonb_array_elements(p_rows) r where lower(trim(coalesce(r->>'work_email', ''))) = v_manager_email)
        and not exists (select 1 from public.people p join public.employment_periods ep on ep.person_id = p.id
                        join public.employment_statuses es on es.key = ep.status
                        where lower(p.work_email::text) = v_manager_email and ep.company_id = p_company_id and es.counts_as_employed) then
        v_problems := array_append(v_problems, format('Manager "%s" is neither in the file nor employed here', v_manager_email));
      end if;
    end if;

    v_verdicts := v_verdicts || jsonb_build_object(
      'row', v_i, 'full_name', v_name, 'work_email', v_email,
      'ok', cardinality(v_problems) = 0,
      'problems', to_jsonb(v_problems),
      'department_id', v_dept, 'location_id', v_loc);
    if cardinality(v_problems) = 0 then v_ready := v_ready + 1; else v_refused := v_refused + 1; end if;
  end loop;

  if not p_commit then
    return jsonb_build_object('committed', false, 'ready', v_ready, 'refused', v_refused, 'rows', v_verdicts);
  end if;
  if v_refused > 0 then
    raise exception '% row(s) are not ready; fix the file and preview again.', v_refused;
  end if;

  -- -------------------------------------------------------------- write
  v_i := 0;
  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_i := v_i + 1;
    v_email := lower(trim(v_row->>'work_email'));
    v_start := (v_row->>'start_date')::date;
    v_private := jsonb_strip_nulls(jsonb_build_object(
      'birth_date', nullif(trim(coalesce(v_row->>'birth_date', '')), ''),
      'address_line', nullif(trim(coalesce(v_row->>'address', '')), ''),
      'national_id', nullif(trim(coalesce(v_row->>'national_id', '')), ''),
      'bank_name', nullif(trim(coalesce(v_row->>'bank_name', '')), ''),
      'bank_account_number', nullif(trim(coalesce(v_row->>'bank_account_number', '')), ''),
      'emergency_name', nullif(trim(coalesce(v_row->>'emergency_contact_name', '')), ''),
      'emergency_relationship', nullif(trim(coalesce(v_row->>'emergency_contact_relationship', '')), ''),
      'emergency_phone', nullif(trim(coalesce(v_row->>'emergency_contact_phone', '')), '')));
    v_pay := case when nullif(trim(coalesce(v_row->>'salary_amount', '')), '') is not null
      then jsonb_build_object(
        'amount', trim(v_row->>'salary_amount'),
        'currency', upper(trim(coalesce(v_row->>'salary_currency', ''))),
        'pay_basis_key', lower(trim(coalesce(v_row->>'salary_basis', ''))),
        'note', 'Imported')
      end;
    v_result := public.create_employee(jsonb_strip_nulls(jsonb_build_object(
      'full_name', trim(v_row->>'full_name'),
      'preferred_name', nullif(trim(coalesce(v_row->>'preferred_name', '')), ''),
      'work_email', v_email,
      'personal_email', nullif(trim(coalesce(v_row->>'personal_email', '')), ''),
      'phone', nullif(trim(coalesce(v_row->>'phone', '')), ''),
      'company_id', p_company_id,
      'job_title', trim(v_row->>'job_title'),
      'employment_type_key', nullif(trim(coalesce(v_row->>'employment_type_key', '')), ''),
      'department_id', v_verdicts->(v_i - 1)->>'department_id',
      'location_id', v_verdicts->(v_i - 1)->>'location_id',
      'start_date', v_start,
      'start_onboarding', v_start >= current_date,
      'private', case when v_private <> '{}'::jsonb then v_private end,
      'pay', v_pay)));
    v_person := (v_result->>'person_id')::uuid;
    v_ids := v_ids || jsonb_build_object(v_email, v_person);
  end loop;

  -- Managers once everyone exists: from the file first, else already employed here.
  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_manager_email := lower(trim(coalesce(v_row->>'manager_email', '')));
    if v_manager_email = '' then continue; end if;
    v_email := lower(trim(v_row->>'work_email'));
    v_manager := (v_ids->>v_manager_email)::uuid;
    if v_manager is null then
      select p.id into v_manager from public.people p join public.employment_periods ep on ep.person_id = p.id
        join public.employment_statuses es on es.key = ep.status
        where lower(p.work_email::text) = v_manager_email and ep.company_id = p_company_id and es.counts_as_employed
        limit 1;
    end if;
    update public.employment_periods set manager_id = v_manager
      where person_id = (v_ids->>v_email)::uuid and company_id = p_company_id;
  end loop;

  return jsonb_build_object('committed', true, 'ready', v_ready, 'refused', 0, 'rows', v_verdicts, 'people', v_ids);
end $$;
