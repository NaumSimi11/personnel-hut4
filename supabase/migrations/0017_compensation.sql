-- 0017_compensation.sql
-- Compensation as a reviewed change (plan 023, core plan §2): a proposal
-- carries amount, currency, pay basis, effective date and a note; someone
-- else approves or rejects it; approving closes the previous approved
-- record the day before, so history is never overwritten and approved
-- records never overlap. Reads stay as in 0006 (self or salary.view);
-- every write goes through the functions below.

drop policy if exists write on public.compensation_records;
drop function if exists app.can_write_compensation(uuid);

-- One open proposal per employment period at a time.
create unique index compensation_one_open_proposal
  on public.compensation_records (employment_period_id)
  where status = 'proposed';

create or replace function public.propose_compensation(
  p_period_id uuid,
  p_amount numeric,
  p_currency text,
  p_pay_basis_key text,
  p_effective_date date,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period record;
  v_current record;
  v_id uuid;
  v_currency text := upper(trim(coalesce(p_currency, '')));
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.employment_periods where id = p_period_id;
  if not found then
    raise exception 'Employment period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'salary.propose') then
    raise exception 'Proposing compensation requires salary.propose in this company.' using errcode = '42501';
  end if;
  if v_period.status = 'former' then
    raise exception 'This employment has ended.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter the amount.';
  end if;
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter code like EUR or MKD.';
  end if;
  if not exists (select 1 from public.pay_bases where key = p_pay_basis_key) then
    raise exception 'Choose how the amount is expressed.';
  end if;
  if p_effective_date is null then
    raise exception 'Choose the effective date.';
  end if;
  if p_effective_date < v_period.start_date then
    raise exception 'The effective date cannot be before the employment started.';
  end if;
  if v_period.end_date is not null and p_effective_date > v_period.end_date then
    raise exception 'The effective date cannot be after the employment ends (%).', v_period.end_date;
  end if;
  select * into v_current from public.compensation_records
    where employment_period_id = p_period_id and status = 'approved'
    order by effective_date desc limit 1;
  if found and p_effective_date <= v_current.effective_date then
    raise exception 'The effective date must be after the current record started (%).', v_current.effective_date;
  end if;
  if exists (select 1 from public.compensation_records
             where employment_period_id = p_period_id and status = 'proposed') then
    raise exception 'A proposal is already awaiting a decision for this employment.';
  end if;

  insert into public.compensation_records
      (employment_period_id, amount, currency, pay_basis_key, effective_date, status, proposed_by, note)
    values (p_period_id, round(p_amount, 2), v_currency, p_pay_basis_key, p_effective_date, 'proposed', v_me,
            nullif(trim(coalesce(p_note, '')), ''))
    returning id into v_id;
  return jsonb_build_object('record_id', v_id);
end $$;

create or replace function public.decide_compensation(
  p_record_id uuid,
  p_decision text,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_record record;
  v_period record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_record from public.compensation_records where id = p_record_id for update;
  if not found then
    raise exception 'Compensation record not found.';
  end if;
  select * into v_period from public.employment_periods where id = v_record.employment_period_id;
  if not app.has_capability(v_period.company_id, 'salary.approve') then
    raise exception 'Deciding compensation requires salary.approve in this company.' using errcode = '42501';
  end if;
  if v_record.status <> 'proposed' then
    raise exception 'This proposal has already been decided.';
  end if;
  if v_record.proposed_by is not distinct from v_me then
    raise exception 'The person who proposed a change cannot approve it.' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Unknown decision: %', p_decision;
  end if;

  if p_decision = 'rejected' then
    update public.compensation_records
      set status = 'rejected', approved_by = v_me,
          note = case when nullif(trim(coalesce(p_note, '')), '') is null then note
                      else concat_ws(' — ', note, trim(p_note)) end
      where id = p_record_id;
    return jsonb_build_object('status', 'rejected');
  end if;
  -- A proposal left open across a departure can be rejected, never approved.
  if v_period.status = 'former' then
    raise exception 'This employment has ended; the proposal can only be rejected.';
  end if;
  if v_period.end_date is not null and v_record.effective_date > v_period.end_date then
    raise exception 'The effective date (%) is after the employment ends (%); reject and propose again.',
      v_record.effective_date, v_period.end_date;
  end if;
  -- Only the RPC creates approved records and it keeps the newest effective
  -- date last; anything else (a later record written outside it) is refused
  -- rather than left overlapping.
  if exists (select 1 from public.compensation_records
             where employment_period_id = v_record.employment_period_id
               and status = 'approved' and effective_date >= v_record.effective_date) then
    raise exception 'An approved record already starts on or after %.', v_record.effective_date;
  end if;

  -- Close whatever is approved and still open the day before the new record.
  update public.compensation_records
    set status = 'superseded',
        end_date = v_record.effective_date - 1
    where employment_period_id = v_record.employment_period_id
      and status = 'approved'
      and (end_date is null or end_date >= v_record.effective_date);
  update public.compensation_records
    set status = 'approved', approved_by = v_me,
        note = case when nullif(trim(coalesce(p_note, '')), '') is null then note
                    else concat_ws(' — ', note, trim(p_note)) end
    where id = p_record_id;
  return jsonb_build_object('status', 'approved');
end $$;

-- Annualised totals per currency for payroll.summary holders. Working-year
-- assumptions: monthly ×12, daily ×260, hourly ×2080 — stated in the UI.
-- Headcount is distinct people on active employment: drafts and pre-start
-- periods are not on payroll yet, former ones no longer.
create or replace function public.compensation_summary(p_company_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_totals jsonb;
  v_covered int;
  v_uncovered int;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'payroll.summary') then
    raise exception 'Payroll totals require payroll.summary in this company.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.annualised desc), '[]'::jsonb) into v_totals
  from (
    select c.currency,
           count(distinct ep.person_id) as people,
           round(sum(case c.pay_basis_key
                       when 'annual' then c.amount
                       when 'monthly' then c.amount * 12
                       when 'daily' then c.amount * 260
                       when 'hourly' then c.amount * 2080
                       else c.amount end), 2) as annualised
    from public.compensation_records c
    join public.employment_periods ep on ep.id = c.employment_period_id
    where ep.company_id = p_company_id
      and ep.status = 'active'
      and c.status = 'approved'
      and c.effective_date <= current_date
      and (c.end_date is null or c.end_date >= current_date)
    group by c.currency
  ) t;

  select count(*) filter (where covered), count(*) filter (where not covered)
    into v_covered, v_uncovered
  from (
    select ep.person_id,
           bool_or(exists (
             select 1 from public.compensation_records c
             where c.employment_period_id = ep.id and c.status = 'approved'
               and c.effective_date <= current_date and (c.end_date is null or c.end_date >= current_date))) as covered
    from public.employment_periods ep
    where ep.company_id = p_company_id and ep.status = 'active'
    group by ep.person_id
  ) p;

  return jsonb_build_object('totals', v_totals, 'covered', v_covered, 'uncovered', v_uncovered);
end $$;

revoke all on function public.propose_compensation(uuid, numeric, text, text, date, text) from public, anon;
revoke all on function public.decide_compensation(uuid, text, text) from public, anon;
revoke all on function public.compensation_summary(uuid) from public, anon;
grant execute on function public.propose_compensation(uuid, numeric, text, text, date, text) to authenticated, service_role;
grant execute on function public.decide_compensation(uuid, text, text) to authenticated, service_role;
grant execute on function public.compensation_summary(uuid) to authenticated, service_role;
