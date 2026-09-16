-- 0039_employee_record_review.sql
-- Review of 0038 (plan 046), the findings that live in the database:
--   1. One person per work email is now a constraint, not a pre-check: a
--      partial unique index on people.work_email (citext folds case) and the
--      insert catches the violation. The hire path is covered too — it used
--      to skip the check.
--   2. Clearing the national ID clears its hint.
--   3. A hire attaches to an existing person by candidate email only when
--      that person holds no open employment (a rehire); a shared family
--      address must not merge a new hire into a colleague's record.
--   4. A hire from an application always starts the checklist — the
--      blueprint's "exactly one employee and onboarding plan" — whatever the
--      start date; start_onboarding only applies to plain adds and imports.
--   5. app.check_employee(p) returns every problem with the object as text[];
--      create_employee raises the first, import_people shows them per row.
--      The preview and the write cannot disagree any more.
--   6. Indexes the new paths need: plans (employment_period_id) for the
--      idempotent checklist lookup; the email check hits the citext index.

-- ------------------------------------------------------- 1. unique email
create unique index people_work_email_key on public.people (work_email)
  where work_email is not null;

-- ------------------------------------------------------ 2. the hint follows
create or replace function app.private_details_hint() returns trigger
language plpgsql as $$
begin
  new.national_id := nullif(btrim(new.national_id), '');
  new.national_id_hint := case when new.national_id is null then null else right(new.national_id, 4) end;
  return new;
end $$;

-- ------------------------------------------------------- 6. plan lookup
create index plans_period_idx on public.plans (employment_period_id);

-- ------------------------------------------------ 5. one set of rules
/**
 * Every rule about the shape of an employee object, as sentences; empty when
 * the object is fine. Capability and identity are not shape and stay in
 * create_employee. p_company_id is the company the employment lands in (the
 * job's, for a hire), needed for the structure checks.
 */
create or replace function app.check_employee(p jsonb, p_company_id uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  v_problems text[] := '{}';
  v_private jsonb := p -> 'private';
  v_pay jsonb := p -> 'pay';
  v_email text;
  v_start date;
  v_birth date;
  v_amount numeric;
  v_shape public.employment_periods;
  v_checks jsonb := '{}'::jsonb;
  v_type text := nullif(btrim(coalesce(p ->> 'employment_type_key', '')), '');
  v_dept uuid := nullif(p ->> 'department_id', '')::uuid;
  v_loc uuid := nullif(p ->> 'location_id', '')::uuid;
  v_manager uuid := nullif(p ->> 'manager_id', '')::uuid;
begin
  if length(btrim(coalesce(p ->> 'full_name', ''))) < 2 then
    v_problems := array_append(v_problems, 'Enter the full name.');
  end if;
  if length(btrim(coalesce(p ->> 'job_title', ''))) < 2 then
    v_problems := array_append(v_problems, 'Enter the job title.');
  end if;
  begin
    v_start := (p ->> 'start_date')::date;
  exception when others then
    v_start := null;
  end;
  if v_start is null then
    v_problems := array_append(v_problems, 'Choose a start date (YYYY-MM-DD).');
  end if;
  v_email := lower(nullif(btrim(coalesce(p ->> 'work_email', '')), ''));
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    v_problems := array_append(v_problems, 'The work email is not an address.');
  end if;
  v_email := lower(nullif(btrim(coalesce(p ->> 'personal_email', '')), ''));
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    v_problems := array_append(v_problems, 'The personal email is not an address.');
  end if;

  if app.jsonb_has_values(v_private) then
    begin
      v_birth := nullif(v_private ->> 'birth_date', '')::date;
      if v_birth > current_date then
        v_problems := array_append(v_problems, 'The birth date cannot be in the future.');
      end if;
    exception when others then
      v_problems := array_append(v_problems, 'The birth date is not a date (use YYYY-MM-DD).');
    end;
    if nullif(btrim(coalesce(v_private ->> 'national_id', '')), '') is not null
       and length(btrim(v_private ->> 'national_id')) not between 4 and 32 then
      v_problems := array_append(v_problems, 'The national ID must be between 4 and 32 characters.');
    end if;
  end if;

  if v_pay is not null and jsonb_typeof(v_pay) = 'object'
     and nullif(btrim(coalesce(v_pay ->> 'amount', '')), '') is not null then
    begin
      v_amount := (v_pay ->> 'amount')::numeric;
      if v_amount <= 0 then
        v_problems := array_append(v_problems, 'The pay amount must be above zero.');
      end if;
    exception when others then
      v_problems := array_append(v_problems, 'The pay amount is not a number.');
    end;
    if upper(btrim(coalesce(v_pay ->> 'currency', ''))) !~ '^[A-Z]{3}$' then
      v_problems := array_append(v_problems, 'Currency must be a three-letter code like EUR or MKD.');
    end if;
    if not exists (select 1 from public.pay_bases b where b.key = lower(btrim(coalesce(v_pay ->> 'pay_basis_key', '')))) then
      v_problems := array_append(v_problems, 'Choose how the pay is expressed (annual, monthly, daily, hourly).');
    end if;
  end if;

  -- The structure checks 0018 already keeps for changes, on the period to be;
  -- the validator raises, so its sentence is collected like the others.
  if p_company_id is not null then
    v_shape.person_id := nullif(p ->> 'person_id', '')::uuid;
    v_shape.company_id := p_company_id;
    if v_dept is not null then v_checks := v_checks || jsonb_build_object('department_id', v_dept); end if;
    if v_loc is not null then v_checks := v_checks || jsonb_build_object('location_id', v_loc); end if;
    if v_manager is not null then v_checks := v_checks || jsonb_build_object('manager_id', v_manager); end if;
    if v_type is not null then v_checks := v_checks || jsonb_build_object('employment_type_key', v_type); end if;
    if v_checks <> '{}'::jsonb then
      begin
        perform app.validate_employment_change(v_shape, v_checks);
      exception when others then
        v_problems := array_append(v_problems, sqlerrm);
      end;
    end if;
  end if;
  return v_problems;
end $$;

-- ------------------------------------------------- 1, 3, 4, 5. the write
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
  v_problems text[];
  v_contacts jsonb := '[]'::jsonb;
  v_bank jsonb;
  v_address jsonb;
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
  v_private_given := app.jsonb_has_values(v_private);
  v_pay_given := v_pay is not null and jsonb_typeof(v_pay) = 'object'
                 and nullif(btrim(coalesce(v_pay ->> 'amount', '')), '') is not null;

  -- Where the employment lands, and whether the caller may put it there.
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
    -- A hire always gets its checklist (blueprint §8), whatever the date.
    v_start_plan := true;
  else
    v_company := nullif(p ->> 'company_id', '')::uuid;
    if v_company is null then
      raise exception 'Choose the employing company.' using errcode = '22023';
    end if;
    if not app.has_capability(v_company, 'employment.edit') then
      raise exception 'Adding an employee requires employment.edit in this company.'
        using errcode = '42501';
    end if;
    v_start_plan := coalesce((p ->> 'start_onboarding')::boolean, true);
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

  -- Identity first, so the shape check can see the person for the manager loop.
  -- A hire attaches to the person the candidate's email already belongs to
  -- only when they hold no open employment — a rehire; a shared address never
  -- merges a new hire into a colleague's record.
  if v_application is not null then
    select p2.id into v_person from public.people p2
      where v_candidate.email is not null
        and (p2.work_email = v_candidate.email or p2.personal_email = v_candidate.email)
        and not exists (
          select 1 from public.employment_periods ep
          join public.employment_statuses es on es.key = ep.status
          where ep.person_id = p2.id and es.counts_as_employed)
      order by p2.created_at
      limit 1;
    -- The address they applied from stays personal unless the caller says otherwise.
    if v_work_email is null and v_personal_email is null and v_candidate.email is not null then
      v_personal_email := lower(v_candidate.email::text);
    end if;
  end if;

  v_problems := app.check_employee(p || jsonb_build_object('person_id', v_person), v_company);
  if cardinality(v_problems) > 0 then
    raise exception '%', v_problems[1] using errcode = '22023';
  end if;
  v_start := (p ->> 'start_date')::date;

  if v_person is null then
    begin
      insert into public.people (full_name, preferred_name, work_email, personal_email, phone)
        values (v_name, v_preferred, v_work_email, v_personal_email, v_phone)
        returning id into v_person;
    exception when unique_violation then
      raise exception 'A person with this work email already exists — open their record and add the employment there.'
        using errcode = '23505';
    end;
  else
    begin
      update public.people
         set preferred_name = coalesce(v_preferred, preferred_name),
             work_email = coalesce(v_work_email, work_email),
             personal_email = coalesce(v_personal_email, personal_email),
             phone = coalesce(v_phone, phone)
       where id = v_person;
    exception when unique_violation then
      raise exception 'Another person already has that work email.' using errcode = '23505';
    end;
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
      values (v_person, nullif(v_private ->> 'birth_date', '')::date, v_address,
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
      v_period, (v_pay ->> 'amount')::numeric, v_pay ->> 'currency', lower(btrim(v_pay ->> 'pay_basis_key')), v_start,
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

-- A file row in create_employee's shape — used by the preview and the write,
-- so what the reader saw is exactly what gets written. A checklist starts
-- for someone starting today or later; a backfill gets none.
create or replace function app.import_row_to_employee(
  v_row jsonb, p_company_id uuid, p_dept uuid, p_loc uuid
) returns jsonb
language plpgsql stable as $$
declare
  v_private jsonb;
  v_pay jsonb;
  v_start date;
begin
  begin
    v_start := (v_row->>'start_date')::date;
  exception when others then
    v_start := null;
  end;
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
  return jsonb_strip_nulls(jsonb_build_object(
    'full_name', trim(coalesce(v_row->>'full_name', '')),
    'preferred_name', nullif(trim(coalesce(v_row->>'preferred_name', '')), ''),
    'work_email', lower(nullif(trim(coalesce(v_row->>'work_email', '')), '')),
    'personal_email', nullif(trim(coalesce(v_row->>'personal_email', '')), ''),
    'phone', nullif(trim(coalesce(v_row->>'phone', '')), ''),
    'company_id', p_company_id,
    'job_title', trim(coalesce(v_row->>'job_title', '')),
    'employment_type_key', nullif(trim(coalesce(v_row->>'employment_type_key', '')), ''),
    'department_id', p_dept,
    'location_id', p_loc,
    'start_date', v_row->>'start_date',
    'start_onboarding', case when v_start is null then true else v_start >= current_date end,
    'private', case when v_private <> '{}'::jsonb then v_private end,
    'pay', v_pay));
end $$;

-- ------------------------------------------ 5. import shows the same rules
-- Per row: the shared checker's sentences, plus what only a file can get
-- wrong (duplicates within it, names to look up). The write is unchanged:
-- every row through create_employee.
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
  v_start date;
  v_dept uuid;
  v_loc uuid;
  v_manager_email text;
  v_ready int := 0;
  v_refused int := 0;
  v_ids jsonb := '{}'::jsonb;    -- email → person id, for manager links
  v_person uuid;
  v_manager uuid;
  v_private_cols text[] := array['birth_date', 'address', 'national_id', 'bank_name', 'bank_account_number',
    'emergency_contact_name', 'emergency_contact_relationship', 'emergency_contact_phone'];
  v_has_private boolean := false;
  v_has_salary boolean := false;
  v_col text;
  v_result jsonb;
  v_shaped jsonb;
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
      if nullif(btrim(coalesce(v_row ->> v_col, '')), '') is not null then
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
    v_name := trim(coalesce(v_row->>'full_name', ''));
    v_email := lower(trim(coalesce(v_row->>'work_email', '')));
    v_manager_email := lower(trim(coalesce(v_row->>'manager_email', '')));
    v_dept := null;
    v_loc := null;

    -- What only a file can get wrong.
    v_problems := '{}';
    if v_email = '' then
      v_problems := array_append(v_problems, 'Work email is missing');
    elsif v_email = any(v_emails) then
      v_problems := array_append(v_problems, 'Work email appears twice in the file');
    elsif exists (select 1 from public.people p where p.work_email = v_email) then
      v_problems := array_append(v_problems, 'A person with this work email already exists');
    end if;
    v_emails := v_emails || v_email;
    if nullif(trim(coalesce(v_row->>'employment_type_key', '')), '') is not null
       and not exists (select 1 from public.employment_types t where t.key = trim(v_row->>'employment_type_key') and t.archived_at is null) then
      v_problems := array_append(v_problems, format('Employment type "%s" is unknown', trim(v_row->>'employment_type_key')));
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
                        where p.work_email = v_manager_email and ep.company_id = p_company_id and es.counts_as_employed) then
        v_problems := array_append(v_problems, format('Manager "%s" is neither in the file nor employed here', v_manager_email));
      end if;
    end if;

    -- The rest are the rules create_employee applies, from the same function.
    v_shaped := app.import_row_to_employee(v_row, p_company_id, v_dept, v_loc);
    v_problems := v_problems || app.check_employee(v_shaped, p_company_id);

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
    v_result := public.create_employee(app.import_row_to_employee(
      v_row, p_company_id,
      (v_verdicts->(v_i - 1)->>'department_id')::uuid,
      (v_verdicts->(v_i - 1)->>'location_id')::uuid));
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
        where p.work_email = v_manager_email and ep.company_id = p_company_id and es.counts_as_employed
        limit 1;
    end if;
    update public.employment_periods set manager_id = v_manager
      where person_id = (v_ids->>v_email)::uuid and company_id = p_company_id;
  end loop;

  return jsonb_build_object('committed', true, 'ready', v_ready, 'refused', 0, 'rows', v_verdicts, 'people', v_ids);
end $$;
