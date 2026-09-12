-- 0028_field_notebook_import.sql
-- Import from Field Notebook (plan 037): one function takes the whole
-- extract as JSON, decides every row, writes all or nothing, and refuses
-- the transaction unless every imported balance recomputes to the number
-- the source shows. p_commit = false runs the same code and returns the
-- report without writing. Platform admins only.

create or replace function app.fn_country_code(p_name text) returns char(2)
language sql immutable as $$
  select case lower(trim(p_name))
    when 'north macedonia' then 'MK'
    when 'macedonia' then 'MK'
    when 'serbia' then 'RS'
    when 'malta' then 'MT'
    else null end
$$;

create or replace function public.import_field_notebook(p_payload jsonb, p_commit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_year int := coalesce((p_payload->>'year')::int, 2026);
  v_row jsonb;
  v_problems text[];
  v_refused int := 0;
  v_verdicts jsonb := '[]'::jsonb;
  v_assumptions jsonb := '[]'::jsonb;
  v_skipped_holidays jsonb := '[]'::jsonb;
  v_grants jsonb := '[]'::jsonb;
  v_balances jsonb := '[]'::jsonb;
  v_counts jsonb;
  -- resolved lookups
  v_company_by_fn jsonb := '{}'::jsonb;    -- fn company name -> company uuid
  v_company_by_code jsonb := '{}'::jsonb;  -- short code (current or renamed-to) -> company uuid
  v_company_country jsonb := '{}'::jsonb;  -- company uuid -> majority country code
  v_person_by_fn jsonb := '{}'::jsonb;     -- fn person id -> person uuid
  v_period_by_fn jsonb := '{}'::jsonb;     -- fn person id -> employment period uuid
  v_person_by_email jsonb := '{}'::jsonb;  -- lower email -> person uuid (source people + existing)
  v_company uuid;
  v_person uuid;
  v_period uuid;
  v_dept uuid;
  v_loc uuid;
  v_balance uuid;
  v_email text;
  v_code char(2);
  v_start date;
  v_status text;
  v_end date;
  v_n int;
  v_people_created int := 0;
  v_people_linked int := 0;
  v_requests int := 0;
  v_requests_skipped int := 0;
  v_adjustments int := 0;
  v_holidays int := 0;
  v_fn_remaining numeric;
  v_computed numeric;
  v_diff numeric;
  v_grant uuid;
  v_sc text;
  v_type_key text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.is_admin() then
    raise exception 'Importing from Field Notebook needs platform admin access.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_payload->'people') <> 'array' or jsonb_typeof(p_payload->'companies') <> 'array' then
    raise exception 'The payload needs "companies" and "people" arrays.';
  end if;

  -- Actors (who decided, who cancelled) may be people Personnel already knows.
  select coalesce(jsonb_object_agg(lower(work_email), id), '{}'::jsonb) into v_person_by_email
  from public.people where work_email is not null and archived_at is null;

  -- ---------------------------------------------------------- companies
  -- {fn_name, short_code, rename_to?, new_short_code?}
  for v_row in select * from jsonb_array_elements(p_payload->'companies') loop
    -- By the current code, or by the new one once a re-run follows the rename.
    select id into v_company from public.companies
      where short_code in (v_row->>'short_code', v_row->>'new_short_code') and archived_at is null
      order by (short_code = v_row->>'short_code') desc limit 1;
    if v_company is null then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'company', 'name', v_row->>'fn_name',
        'problems', to_jsonb(array[format('no company with short code %s', v_row->>'short_code')]));
      v_refused := v_refused + 1;
      continue;
    end if;
    v_company_by_fn := v_company_by_fn || jsonb_build_object(lower(v_row->>'fn_name'), v_company);
    v_company_by_code := v_company_by_code || jsonb_build_object(v_row->>'short_code', v_company);
    if v_row->>'new_short_code' is not null then
      v_company_by_code := v_company_by_code || jsonb_build_object(v_row->>'new_short_code', v_company);
    end if;
    if p_commit and v_row->>'rename_to' is not null then
      update public.companies set name = v_row->>'rename_to', short_code = coalesce(v_row->>'new_short_code', short_code)
        where id = v_company;
    end if;
    if v_row->>'rename_to' is not null then
      v_assumptions := v_assumptions || jsonb_build_object('company', v_row->>'short_code', 'renamed_to', v_row->>'rename_to',
        'new_short_code', v_row->>'new_short_code');
    end if;
  end loop;

  -- Majority country of each company's active people decides its calendar
  -- when the company has none yet.
  for v_row in
    select jsonb_build_object('company_id', c.company_id, 'code', (
      select app.fn_country_code(p->>'country')
      from jsonb_array_elements(p_payload->'people') p
      where (v_company_by_fn->>lower(p->>'company')) = c.company_id and coalesce((p->>'is_active')::boolean, true)
      group by 1 order by count(*) desc, 1 limit 1))
    from (select distinct value as company_id from jsonb_each_text(v_company_by_fn)) c
  loop
    -- A country the company already has wins; the source only fills a blank.
    v_code := coalesce((select country_code from public.companies where id = (v_row->>'company_id')::uuid), v_row->>'code', 'MK');
    v_company_country := v_company_country || jsonb_build_object(v_row->>'company_id', v_code);
    if (select country_code from public.companies where id = (v_row->>'company_id')::uuid) is null then
      v_assumptions := v_assumptions || jsonb_build_object('company_id', v_row->>'company_id', 'country_code', v_code,
        'why', case when v_row->>'code' is null then 'no active people in the source; MK assumed' else 'majority country of its active people' end);
      if p_commit then
        update public.companies set country_code = v_code where id = (v_row->>'company_id')::uuid;
      end if;
    end if;
  end loop;

  -- ------------------------------------------------------------- people
  -- {fn_id, name, email, phone, company, country, department, position, is_active, allowance, remaining, updated_at, first_request}
  for v_row in select * from jsonb_array_elements(p_payload->'people') loop
    v_problems := '{}';
    v_email := lower(trim(coalesce(v_row->>'email', '')));
    if v_email = '' then v_problems := array_append(v_problems, 'no email'); end if;
    if coalesce(v_row->>'name', '') = '' then v_problems := array_append(v_problems, 'no name'); end if;
    v_company := (v_company_by_fn->>lower(coalesce(v_row->>'company', '')))::uuid;
    if v_company is null then v_problems := array_append(v_problems, format('company "%s" is not mapped', v_row->>'company')); end if;
    if app.fn_country_code(v_row->>'country') is null then v_problems := array_append(v_problems, format('country "%s" is unknown', v_row->>'country')); end if;
    if v_email <> '' and exists (select 1 from jsonb_array_elements(p_payload->'people') q
                                 where lower(trim(coalesce(q->>'email', ''))) = v_email and (q->>'fn_id')::int < (v_row->>'fn_id')::int) then
      v_problems := array_append(v_problems, 'email appears twice in the source');
    end if;
    if cardinality(v_problems) > 0 then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'person', 'name', v_row->>'name', 'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;

    select id into v_person from public.people where lower(work_email) = v_email and archived_at is null;
    v_start := least(date '2026-01-01', coalesce((v_row->>'first_request')::date, date '2026-01-01'));
    if coalesce((v_row->>'is_active')::boolean, true) then
      v_status := 'active'; v_end := null;
    else
      v_status := 'former'; v_end := greatest(v_start, coalesce((v_row->>'updated_at')::date, current_date));
    end if;
    -- A linked person employed elsewhere over the same dates cannot get a
    -- second employment here (no_overlapping_employment): transfer them first.
    if v_person is not null
       and not exists (select 1 from public.employment_periods where person_id = v_person and company_id = v_company)
       and exists (select 1 from public.employment_periods ep where ep.person_id = v_person and ep.company_id <> v_company
                   and daterange(ep.start_date, coalesce(ep.end_date, 'infinity'::date), '[]') && daterange(v_start, coalesce(v_end, 'infinity'::date), '[]')) then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'person', 'name', v_row->>'name',
        'problems', to_jsonb(array[format('already employed in another company over these dates; transfer them to %s first', v_row->>'company')]));
      v_refused := v_refused + 1;
      continue;
    end if;

    if v_person is not null then
      v_people_linked := v_people_linked + 1;
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'person', 'name', v_row->>'name', 'action', 'linked to the existing record');
    else
      v_people_created := v_people_created + 1;
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'person', 'name', v_row->>'name', 'action', 'created',
        'status', v_status, 'start_date', v_start);
      if p_commit then
        insert into public.people (full_name, work_email, phone, custom)
        values (trim(v_row->>'name'), v_email, nullif(trim(coalesce(v_row->>'phone', '')), ''),
                jsonb_build_object('field_notebook', jsonb_build_object('id', (v_row->>'fn_id')::int, 'start_date_assumed', true)))
        returning id into v_person;
      else
        v_person := gen_random_uuid();  -- placeholder so later rows resolve during the dry run
      end if;
    end if;
    v_person_by_fn := v_person_by_fn || jsonb_build_object(v_row->>'fn_id', v_person);
    v_person_by_email := v_person_by_email || jsonb_build_object(v_email, v_person);

    if p_commit then
      -- Department shared across companies, created by name when missing.
      v_dept := null;
      if coalesce(v_row->>'department', '') <> '' then
        select id into v_dept from public.departments where company_id is null and lower(name) = lower(v_row->>'department') and archived_at is null;
        if v_dept is null then
          insert into public.departments (company_id, name) values (null, trim(v_row->>'department')) returning id into v_dept;
        end if;
      end if;
      -- A location only when the person's country differs from the company's.
      v_loc := null;
      v_code := app.fn_country_code(v_row->>'country');
      if v_code <> (v_company_country->>v_company::text) then
        select id into v_loc from public.locations where company_id = v_company and archived_at is null
          and (country_code = v_code or (country_code is null and lower(name) = lower(trim(v_row->>'country'))))
          order by (country_code = v_code) desc nulls last limit 1;
        if v_loc is not null and (select country_code from public.locations where id = v_loc) is null then
          update public.locations set country_code = v_code where id = v_loc;
        end if;
        if v_loc is null then
          insert into public.locations (company_id, name, country_code) values (v_company, trim(v_row->>'country'), v_code) returning id into v_loc;
        end if;
      end if;
      -- A linked person keeps whatever employment they already have here
      -- (the current one first); only people without any get one created.
      select id into v_period from public.employment_periods
        where person_id = v_person and company_id = v_company
        order by (status in ('active', 'pre_start')) desc, start_date desc limit 1;
      if v_period is null then
        insert into public.employment_periods (person_id, company_id, job_title, department_id, location_id, employment_type_key, status, start_date, end_date, custom)
        values (v_person, v_company, coalesce(nullif(trim(v_row->>'position'), ''), 'Employee'), v_dept, v_loc, 'full_time', v_status, v_start, v_end,
                jsonb_build_object('field_notebook', jsonb_build_object('id', (v_row->>'fn_id')::int, 'start_date_assumed', true)))
        returning id into v_period;
      end if;
      v_period_by_fn := v_period_by_fn || jsonb_build_object(v_row->>'fn_id', v_period);
    end if;
  end loop;

  -- ----------------------------------------------------------- requests
  -- {fn_id, person_fn_id, type, start, end, working_days, carry_over_used, note, status, documents_to_follow,
  --  submitted_by_email, decided_by_email, decided_at, cancelled_by_email, cancelled_at, cancellation_reason,
  --  cancellation_requested_at, cancellation_request_reason, cancellation_declined_at, cancellation_declined_by_email,
  --  cancellation_decline_note, created_at}
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'requests', '[]'::jsonb)) loop
    v_problems := '{}';
    v_person := (v_person_by_fn->>(v_row->>'person_fn_id'))::uuid;
    if v_person is null then v_problems := array_append(v_problems, 'person not imported'); end if;
    select key into v_type_key from public.leave_types where lower(label) = lower(coalesce(v_row->>'type', ''));
    if v_type_key is null then v_problems := array_append(v_problems, format('leave type "%s" is unknown', v_row->>'type')); end if;
    if v_row->>'status' not in ('pending', 'approved', 'rejected', 'cancelled') then v_problems := array_append(v_problems, format('status "%s" is unknown', v_row->>'status')); end if;
    if (v_row->>'end')::date < (v_row->>'start')::date then v_problems := array_append(v_problems, 'end before start'); end if;
    if cardinality(v_problems) > 0 then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'request', 'legacy_id', v_row->>'fn_id', 'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;
    if exists (select 1 from public.leave_requests where legacy_id = (v_row->>'fn_id')::int) then
      v_requests_skipped := v_requests_skipped + 1;
      continue;
    end if;
    v_requests := v_requests + 1;
    if p_commit then
      v_period := (v_period_by_fn->>(v_row->>'person_fn_id'))::uuid;
      insert into public.leave_requests (
        person_id, employment_period_id, company_id, leave_type_key, deducts_balance, requires_document,
        start_date, end_date, working_days, carry_over_days_used, note, status, documents_to_follow,
        submitted_by, decided_by, decided_at, decision_note,
        cancelled_by, cancelled_at, cancellation_reason,
        cancellation_requested_at, cancellation_request_reason,
        cancellation_declined_at, cancellation_declined_by, cancellation_decline_note,
        legacy_id, created_at, updated_at)
      select v_person, v_period, ep.company_id, lt.key, lt.deducts_balance, lt.requires_document,
        (v_row->>'start')::date, (v_row->>'end')::date, coalesce((v_row->>'working_days')::int, 0), coalesce((v_row->>'carry_over_used')::int, 0),
        nullif(v_row->>'note', ''), v_row->>'status', coalesce((v_row->>'documents_to_follow')::boolean, false),
        (v_person_by_email->>lower(coalesce(v_row->>'submitted_by_email', '')))::uuid,
        (v_person_by_email->>lower(coalesce(v_row->>'decided_by_email', '')))::uuid,
        (v_row->>'decided_at')::timestamptz, null,
        (v_person_by_email->>lower(coalesce(v_row->>'cancelled_by_email', '')))::uuid,
        (v_row->>'cancelled_at')::timestamptz, nullif(v_row->>'cancellation_reason', ''),
        (v_row->>'cancellation_requested_at')::timestamptz, nullif(v_row->>'cancellation_request_reason', ''),
        (v_row->>'cancellation_declined_at')::timestamptz,
        (v_person_by_email->>lower(coalesce(v_row->>'cancellation_declined_by_email', '')))::uuid,
        nullif(v_row->>'cancellation_decline_note', ''),
        (v_row->>'fn_id')::int, coalesce((v_row->>'created_at')::timestamptz, now()), coalesce((v_row->>'created_at')::timestamptz, now())
      from public.employment_periods ep, public.leave_types lt
      where ep.id = v_period and lt.key = v_type_key;
    end if;
  end loop;

  -- ----------------------------------------------------------- balances
  for v_row in select * from jsonb_array_elements(p_payload->'people') loop
    v_person := (v_person_by_fn->>(v_row->>'fn_id'))::uuid;
    if v_person is null then continue; end if;
    v_company := (v_company_by_fn->>lower(v_row->>'company'))::uuid;
    v_fn_remaining := coalesce((v_row->>'remaining')::numeric, 0);
    if not p_commit then
      -- What the commit will have to reconcile: entitlement minus this
      -- year's approved deducting days plus the real adjustments, against
      -- the source's number.
      v_computed := coalesce((v_row->>'allowance')::numeric, 0)
        - coalesce((select sum((r->>'working_days')::numeric - coalesce((r->>'carry_over_used')::numeric, 0)) from jsonb_array_elements(coalesce(p_payload->'requests', '[]'::jsonb)) r
                    join public.leave_types lt on lower(lt.label) = lower(r->>'type')
                    where r->>'person_fn_id' = v_row->>'fn_id' and r->>'status' = 'approved' and lt.deducts_balance
                      and extract(year from (r->>'start')::date) = v_year), 0)
        + coalesce((select sum((a->>'days')::numeric) from jsonb_array_elements(coalesce(p_payload->'adjustments', '[]'::jsonb)) a
                    where a->>'person_fn_id' = v_row->>'fn_id' and a->>'kind' in ('manual_adjustment', 'allowance_update')), 0);
      v_balances := v_balances || jsonb_build_object('name', v_row->>'name', 'entitlement', (v_row->>'allowance')::numeric,
        'source_remaining', v_fn_remaining, 'remaining', v_computed, 'reconciled_by', v_fn_remaining - v_computed,
        'verified', 'on commit (estimate: existing Personnel data not counted)');
      continue;
    end if;
    -- The source keeps no carry-over row; what its approved requests drew
    -- from carry-over is the least it must have had.
    insert into public.leave_balances (person_id, company_id, year, entitlement_days, carry_over_days, carry_over_expires_on)
    values (v_person, v_company, v_year, coalesce((v_row->>'allowance')::numeric, 0),
            coalesce((select sum(coalesce((r->>'carry_over_used')::numeric, 0)) from jsonb_array_elements(coalesce(p_payload->'requests', '[]'::jsonb)) r
                      where r->>'person_fn_id' = v_row->>'fn_id' and r->>'status' = 'approved'
                        and extract(year from (r->>'start')::date) = v_year), 0),
            app.carry_over_expiry(v_company, v_year))
    on conflict (person_id, company_id, year) do update
      set entitlement_days = excluded.entitlement_days, carry_over_days = greatest(public.leave_balances.carry_over_days, excluded.carry_over_days)
    returning id into v_balance;
    -- Real adjustments from the source, with their reasons.
    insert into public.leave_adjustments (balance_id, company_id, days, kind, reason, created_by, created_at)
    select v_balance, v_company, (a->>'days')::numeric, 'import',
      format('Field Notebook %s: %s', replace(a->>'kind', '_', ' '), coalesce(nullif(a->>'reason', ''), 'no reason given')),
      (v_person_by_email->>lower(coalesce(a->>'created_by_email', '')))::uuid,
      coalesce((a->>'created_at')::timestamptz, make_date(v_year, 1, 1)::timestamptz)
    from jsonb_array_elements(coalesce(p_payload->'adjustments', '[]'::jsonb)) a
    where a->>'person_fn_id' = v_row->>'fn_id' and a->>'kind' in ('manual_adjustment', 'allowance_update')
      -- a re-run never doubles an adjustment already carried over
      and not exists (select 1 from public.leave_adjustments x where x.balance_id = v_balance and x.kind = 'import'
                      and x.days = (a->>'days')::numeric and x.created_at = coalesce((a->>'created_at')::timestamptz, make_date(v_year, 1, 1)::timestamptz)
                      and x.reason like 'Field Notebook ' || replace(a->>'kind', '_', ' ') || ':%');
    get diagnostics v_n = row_count;
    v_adjustments := v_adjustments + v_n;
    -- Reconcile whatever is left to the number the source shows.
    v_computed := (public.leave_balance(v_person, v_company, v_year)->>'remaining')::numeric;
    v_diff := v_fn_remaining - v_computed;
    if v_diff <> 0 then
      insert into public.leave_adjustments (balance_id, company_id, days, kind, reason, created_by)
      values (v_balance, v_company, v_diff, 'import',
        format('Field Notebook reconciliation: source showed %s days remaining, entitlement minus approved leave gave %s', v_fn_remaining, v_computed), v_me);
      v_adjustments := v_adjustments + 1;
    end if;
    v_computed := (public.leave_balance(v_person, v_company, v_year)->>'remaining')::numeric;
    v_balances := v_balances || jsonb_build_object('name', v_row->>'name', 'entitlement', (v_row->>'allowance')::numeric,
      'source_remaining', v_fn_remaining, 'remaining', v_computed, 'reconciled_by', v_diff, 'verified', v_computed = v_fn_remaining);
    if v_computed <> v_fn_remaining then
      raise exception 'Verification failed for %: source remaining % but Personnel computes % — nothing was written.',
        v_row->>'name', v_fn_remaining, v_computed;
    end if;
  end loop;

  -- ----------------------------------------------------------- holidays
  -- {country, date, name, universal}
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'holidays', '[]'::jsonb)) loop
    v_code := app.fn_country_code(v_row->>'country');
    if v_code is null then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'holiday', 'name', v_row->>'name', 'problems', to_jsonb(array[format('country "%s" is unknown', v_row->>'country')]));
      v_refused := v_refused + 1;
      continue;
    end if;
    if not coalesce((v_row->>'universal')::boolean, true) then
      v_skipped_holidays := v_skipped_holidays || jsonb_build_object('country', v_code, 'date', v_row->>'date', 'name', v_row->>'name',
        'why', 'per faith or community; the calendar holds one list per country');
      continue;
    end if;
    v_holidays := v_holidays + 1;
    if p_commit then
      insert into public.public_holidays (country_code, date, name, kind)
      values (v_code, (v_row->>'date')::date, trim(v_row->>'name'), 'statutory')
      on conflict (country_code, date) do update set name = excluded.name;
    end if;
  end loop;

  -- ---------------------------------------------------------- approvers
  -- {email, short_codes: [...]}
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'approvers', '[]'::jsonb)) loop
    v_email := lower(trim(coalesce(v_row->>'email', '')));
    v_person := (v_person_by_email->>v_email)::uuid;
    if v_person is null then
      select id into v_person from public.people where lower(work_email) = v_email and archived_at is null;
    end if;
    if v_person is null then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'approver', 'email', v_email, 'problems', to_jsonb(array['no person with this email']));
      v_refused := v_refused + 1;
      continue;
    end if;
    for v_sc in select jsonb_array_elements_text(coalesce(v_row->'short_codes', '[]'::jsonb)) loop
      v_company := (v_company_by_code->>v_sc)::uuid;
      if v_company is null then
        select id into v_company from public.companies where short_code = v_sc and archived_at is null;
      end if;
      if v_company is null then
        v_verdicts := v_verdicts || jsonb_build_object('kind', 'approver', 'email', v_email, 'problems', to_jsonb(array[format('no company %s', v_sc)]));
        v_refused := v_refused + 1;
        continue;
      end if;
      v_grants := v_grants || jsonb_build_object('email', v_email, 'company', v_sc,
        'capabilities', jsonb_build_array('leave.view', 'leave.approve', 'leave.adjust', 'holidays.manage'));
      if p_commit then
        insert into public.access_grants (person_id, company_id, granted_by, note)
        values (v_person, v_company, v_me, 'Field Notebook administrator')
        on conflict (person_id, company_id) do update set updated_at = now()
        returning id into v_grant;
        insert into public.grant_capabilities (grant_id, capability_key)
        values (v_grant, 'leave.view'), (v_grant, 'leave.approve'), (v_grant, 'leave.adjust'), (v_grant, 'holidays.manage')
        on conflict do nothing;
      end if;
    end loop;
  end loop;

  v_counts := jsonb_build_object(
    'people_created', v_people_created, 'people_linked', v_people_linked,
    'requests', v_requests, 'requests_already_there', v_requests_skipped,
    'adjustments', v_adjustments, 'holidays', v_holidays, 'holidays_skipped', jsonb_array_length(v_skipped_holidays),
    'grants', jsonb_array_length(v_grants), 'refused', v_refused);

  if v_refused > 0 and p_commit then
    raise exception '% row(s) refused; fix the extract and run the dry run again.', v_refused;
  end if;
  if p_commit then
    insert into public.activity_log (actor_person_id, actor_user_id, entity_type, entity_id, action, after)
    values (v_me, auth.uid(), 'field_notebook_import', null, 'INSERT', v_counts);
  end if;
  return jsonb_build_object('committed', p_commit, 'counts', v_counts, 'rows', v_verdicts,
    'assumptions', v_assumptions, 'skipped_holidays', v_skipped_holidays, 'grants', v_grants, 'balances', v_balances);
end $$;

revoke all on function public.import_field_notebook(jsonb, boolean) from public;
grant execute on function public.import_field_notebook(jsonb, boolean) to authenticated;
