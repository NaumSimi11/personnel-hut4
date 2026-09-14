-- 0032_leave_corrections.sql
-- Correcting approved leave (plan 041, ported from Field Notebook's Manager
-- desk): HR fixes what actually happened — other dates, a day that was sick
-- rather than annual — and the balance follows: extra days are taken from
-- the year (checked the way an approval is), dropped days go back to the
-- person, because the balance is always derived from the approved rows.
-- Every correction is kept: the old picture, the new one, who and why.

create table public.leave_corrections (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.leave_requests(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  person_id uuid not null references public.people(id),
  old_start date not null,
  old_end date not null,
  old_leave_type_key text not null,
  old_working_days int not null,
  new_start date not null,
  new_end date not null,
  new_leave_type_key text not null,
  new_working_days int not null,
  split_request_ids uuid[] not null default '{}',
  note text,
  corrected_by uuid references public.people(id),
  corrected_at timestamptz not null default now()
);
create index leave_corrections_request_idx on public.leave_corrections (request_id, corrected_at desc);
alter table public.leave_corrections enable row level security;
create policy sel on public.leave_corrections for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'leave.view') or app.has_capability(company_id, 'leave.approve'));
grant select on public.leave_corrections to authenticated;
grant all on public.leave_corrections to service_role;
create trigger audit after insert on public.leave_corrections for each row execute function app.audit_redacted('note');

-- A request that came out of a split remembers where from.
alter table public.leave_requests add column corrected_from_id uuid references public.leave_requests(id);

/**
 * p_days: [{"date": "2026-12-02", "leave_type_key": "annual"}, ...] — every
 * working day the leave should now cover, with its type. Non-working days
 * are refused (they never count). Consecutive working days of one type form
 * one request: the first run keeps the original row (its id, history and
 * documents), further runs become new approved rows linked back.
 */
create or replace function public.correct_leave(p_request_id uuid, p_days jsonb, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
  v_country char(2);
  v_b record;
  v_d record;
  v_run record;
  v_type record;
  v_runs jsonb := '[]'::jsonb;
  v_planned jsonb := '[]'::jsonb;
  v_run_start date; v_run_end date; v_run_type text; v_run_days int := 0; v_prev date;
  v_co int; v_co_left numeric;
  v_allocated jsonb := '{}'::jsonb;      -- carry-over drawn by earlier runs of this correction, per year
  v_y int; v_need int; v_left numeric;
  v_first boolean := true;
  v_new_ids uuid[] := '{}';
  v_new_id uuid;
  v_first_start date; v_first_end date; v_first_type text; v_first_days int;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_r from public.leave_requests where id = p_request_id for update;
  if not found then
    raise exception 'Leave request not found.';
  end if;
  if not app.has_capability(v_r.company_id, 'leave.approve') then
    raise exception 'Correcting leave needs leave.approve in this company.' using errcode = '42501';
  end if;
  if v_r.person_id = v_me and not app.is_admin() then
    raise exception 'You cannot correct your own leave.' using errcode = '42501';
  end if;
  if v_r.status <> 'approved' then
    raise exception 'Only approved leave can be corrected; decide a pending request, or file it again.';
  end if;
  if jsonb_typeof(p_days) <> 'array' or jsonb_array_length(p_days) = 0 then
    raise exception 'Choose at least one working day.';
  end if;
  perform pg_advisory_xact_lock(hashtext('leave:' || v_r.person_id::text));
  v_country := app.employment_country(v_r.employment_period_id);
  if v_country is null then
    raise exception 'The company (or the person''s location) has no country yet, so holidays cannot be excluded. Set it first.';
  end if;

  -- ---------------------------------------------------------------- runs
  -- Walk the days in order; each must be a working day with a known type.
  -- A run ends when the type changes or a working day is skipped.
  for v_d in
    select (d->>'date')::date as day, d->>'leave_type_key' as type_key
    from jsonb_array_elements(p_days) d order by 1
  loop
    if app.working_days(v_d.day, v_d.day, v_country, v_r.company_id) = 0 then
      raise exception '% is not a working day (weekends, holidays and closures never count).', v_d.day;
    end if;
    if v_prev is not null and v_d.day = v_prev then
      raise exception '% is listed twice.', v_d.day;
    end if;
    if not exists (select 1 from public.leave_types t where t.key = v_d.type_key and t.is_active) then
      raise exception 'Unknown kind of leave: %.', v_d.type_key;
    end if;
    if v_run_type is null or v_d.type_key <> v_run_type
       or app.working_days(v_run_end, v_d.day, v_country, v_r.company_id) > 2 then
      if v_run_type is not null then
        v_runs := v_runs || jsonb_build_object('start', v_run_start, 'end', v_run_end, 'type', v_run_type, 'days', v_run_days);
      end if;
      v_run_start := v_d.day; v_run_type := v_d.type_key; v_run_days := 0;
    end if;
    v_run_end := v_d.day;
    v_run_days := v_run_days + 1;
    v_prev := v_d.day;
  end loop;
  v_runs := v_runs || jsonb_build_object('start', v_run_start, 'end', v_run_end, 'type', v_run_type, 'days', v_run_days);

  -- No other pending or approved leave may cover the new days.
  if exists (
    select 1 from jsonb_to_recordset(v_runs) as x(start date, "end" date, type text, days int)
    join public.leave_requests o on o.person_id = v_r.person_id and o.id <> v_r.id and o.status in ('pending', 'approved')
      and o.start_date <= x."end" and o.end_date >= x.start) then
    raise exception 'Other leave already covers some of those dates.';
  end if;

  -- ------------------------------------------------------- balance plan
  -- Per run: the carry-over it draws (by window, whole days), the way an
  -- approval does; the year is the run's own, so a leave moved from
  -- December into January is charged to January's balance.
  for v_run in select * from jsonb_to_recordset(v_runs) as x(start date, "end" date, type text, days int) loop
    select * into v_type from public.leave_types where key = v_run.type;
    v_co := 0;
    if v_type.deducts_balance then
      if extract(year from v_run.start) <> extract(year from v_run."end") then
        raise exception 'Annual leave is corrected per leave year: split it at 31 December.';
      end if;
      v_y := extract(year from v_run.start);
      select * into v_b from public.leave_balances
        where person_id = v_r.person_id and company_id = v_r.company_id and year = v_y for update;
      if not found then
        raise exception 'No leave balance exists for % yet; set the entitlement first.', v_y;
      end if;
      v_co_left := greatest(0, v_b.carry_over_days
        - (select coalesce(sum(carry_over_days_used), 0) from public.leave_requests x
             where x.person_id = v_r.person_id and x.company_id = v_r.company_id and x.status = 'approved' and x.deducts_balance
               and extract(year from x.start_date) = v_y and x.id <> v_r.id)
        - coalesce((v_allocated->>v_y::text)::numeric, 0));
      v_co := floor(least(v_co_left, app.carry_over_eligible_days(v_run.start, v_run."end", v_country, v_r.company_id, v_y), v_run.days))::int;
      v_allocated := v_allocated || jsonb_build_object(v_y::text, coalesce((v_allocated->>v_y::text)::numeric, 0) + v_co);
    end if;
    v_planned := v_planned || jsonb_build_object('start', v_run.start, 'end', v_run."end", 'type', v_run.type, 'days', v_run.days,
      'deducts', v_type.deducts_balance, 'requires_document', v_type.requires_document, 'co', v_co);
  end loop;

  -- Per year: what the runs take from the year against what is left once
  -- this request's own days are given back (pending requests reserve too).
  for v_y in select distinct extract(year from x.start)::int from jsonb_to_recordset(v_planned) as x(start date, deducts boolean) where x.deducts loop
    select * into v_b from public.leave_balances where person_id = v_r.person_id and company_id = v_r.company_id and year = v_y;
    select coalesce(sum(x.days - x.co), 0) into v_need
      from jsonb_to_recordset(v_planned) as x(start date, days int, co int, deducts boolean)
      where x.deducts and extract(year from x.start) = v_y;
    v_left := v_b.entitlement_days
      + (select coalesce(sum(days), 0) from public.leave_adjustments a where a.balance_id = v_b.id)
      - (select coalesce(sum(case when x.status = 'approved' then x.working_days - x.carry_over_days_used else x.working_days end), 0)
           from public.leave_requests x
           where x.person_id = v_r.person_id and x.company_id = v_r.company_id and x.status in ('approved', 'pending')
             and x.deducts_balance and extract(year from x.start_date) = v_y and x.id <> v_r.id);
    if v_need > v_left then
      raise exception 'Not enough leave left in %: % day(s) available once this leave is given back, the correction needs % from the year.', v_y, v_left, v_need;
    end if;
  end loop;

  -- --------------------------------------------------------------- write
  for v_run in select * from jsonb_to_recordset(v_planned) as x(start date, "end" date, type text, days int, deducts boolean, requires_document boolean, co int) loop
    if v_first then
      v_first_start := v_run.start; v_first_end := v_run."end"; v_first_type := v_run.type; v_first_days := v_run.days;
      update public.leave_requests
        set start_date = v_run.start, end_date = v_run."end", leave_type_key = v_run.type,
            deducts_balance = v_run.deducts, requires_document = v_run.requires_document,
            working_days = v_run.days, carry_over_days_used = v_run.co
        where id = v_r.id;
      v_first := false;
    else
      insert into public.leave_requests (person_id, employment_period_id, company_id, leave_type_key, deducts_balance, requires_document,
        start_date, end_date, working_days, carry_over_days_used, note, status, documents_to_follow,
        submitted_by, decided_by, decided_at, decision_note, corrected_from_id)
      values (v_r.person_id, v_r.employment_period_id, v_r.company_id, v_run.type, v_run.deducts, v_run.requires_document,
        v_run.start, v_run."end", v_run.days, v_run.co, v_r.note, 'approved', false,
        v_r.submitted_by, v_me, now(), 'Split off by a correction', v_r.id)
      returning id into v_new_id;
      v_new_ids := array_append(v_new_ids, v_new_id);
    end if;
  end loop;

  insert into public.leave_corrections (request_id, company_id, person_id, old_start, old_end, old_leave_type_key, old_working_days,
    new_start, new_end, new_leave_type_key, new_working_days, split_request_ids, note, corrected_by)
  values (v_r.id, v_r.company_id, v_r.person_id, v_r.start_date, v_r.end_date, v_r.leave_type_key, v_r.working_days,
    v_first_start, v_first_end, v_first_type, v_first_days, v_new_ids, v_note, v_me);

  return jsonb_build_object('request_id', v_r.id, 'split_request_ids', to_jsonb(v_new_ids),
    'working_days', (select coalesce(sum(x.days), 0) from jsonb_to_recordset(v_planned) as x(days int)),
    'deducting_before', case when v_r.deducts_balance then v_r.working_days else 0 end,
    'deducting_after', (select coalesce(sum(x.days), 0) from jsonb_to_recordset(v_planned) as x(days int, deducts boolean) where x.deducts));
end $$;
revoke all on function public.correct_leave(uuid, jsonb, text) from public;
grant execute on function public.correct_leave(uuid, jsonb, text) to authenticated;
