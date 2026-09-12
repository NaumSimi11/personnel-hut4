-- 0023_payroll_preparation.sql
-- Payroll preparation (plan 031): a period snapshots the compensation in
-- force for a company in one currency; someone other than the preparer
-- approves it; an exporter hands it off. Lines are facts, never computed pay.

alter table public.payroll_periods
  add column prepared_by uuid references public.people(id),
  add column prepared_at timestamptz;
-- Currency is explicit per period (data-model): one period per range and currency.
alter table public.payroll_periods
  drop constraint payroll_periods_company_id_period_start_period_end_key,
  add constraint payroll_periods_range_currency_key unique (company_id, period_start, period_end, currency);

create table public.payroll_lines (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id) on delete cascade,
  company_id uuid not null references public.companies(id),      -- derived
  person_id uuid not null references public.people(id),
  employment_period_id uuid not null references public.employment_periods(id),
  compensation_record_id uuid references public.compensation_records(id) on delete set null,
  full_name text not null,
  job_title text not null,
  amount numeric(14,2) not null,
  currency char(3) not null,
  pay_basis_key text not null,
  effective_from date not null,       -- the record's start, clamped to the period
  effective_to date not null,         -- the record's end (or the period end), clamped
  days_covered int not null,
  created_at timestamptz not null default now()
);
create index payroll_lines_period_idx on public.payroll_lines (period_id);
alter table public.payroll_lines enable row level security;
create policy sel on public.payroll_lines for select to authenticated
  using (app.has_capability(company_id, 'payroll.individual'));
grant select on public.payroll_lines to authenticated;
grant all on public.payroll_lines to service_role;

-- Status and the approval / export facts move only through the functions;
-- only a draft can be deleted (a prepared period is a record).
drop policy if exists write on public.payroll_periods;
create policy write on public.payroll_periods for all to authenticated
  using (app.has_capability(company_id, 'payroll.individual') and (status = 'draft' or current_setting('app.payroll_transition', true) = 'on'))
  with check (app.has_capability(company_id, 'payroll.individual'));

create or replace function app.prepare_payroll_period_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.currency := upper(trim(coalesce(new.currency, '')));
  if new.currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter code like EUR or MKD.';
  end if;
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.approved_by := null;
    new.exported_at := null;
    new.export_document_id := null;
    new.prepared_by := null;
    new.prepared_at := null;
  elsif auth.uid() is not null and current_setting('app.payroll_transition', true) is distinct from 'on' then
    if old.status <> 'draft' then
      raise exception 'A period that has been prepared changes only through its workflow.';
    end if;
    new.status := old.status;
    new.approved_by := old.approved_by;
    new.exported_at := old.exported_at;
    new.export_document_id := old.export_document_id;
    new.prepared_by := old.prepared_by;
    new.prepared_at := old.prepared_at;
    new.company_id := old.company_id;
  end if;
  new.note := nullif(trim(coalesce(new.note, '')), '');
  return new;
end $$;
create trigger prepare_payroll_period before insert or update on public.payroll_periods
  for each row execute function app.prepare_payroll_period_row();

create or replace function public.prepare_payroll_period(
  p_company_id uuid,
  p_start date,
  p_end date,
  p_currency text,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_currency text := upper(trim(coalesce(p_currency, '')));
  v_period record;
  v_id uuid;
  v_lines int;
  v_uncovered int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'payroll.individual') then
    raise exception 'Preparing payroll needs payroll.individual in this company.' using errcode = '42501';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'Choose the period: the end must not be before the start.';
  end if;
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter code like EUR or MKD.';
  end if;

  select * into v_period from public.payroll_periods
    where company_id = p_company_id and period_start = p_start and period_end = p_end and currency = v_currency
    for update;
  if found then
    if v_period.status not in ('draft', 'in_review') then
      raise exception 'This period is already %; reopen it to prepare it again.', v_period.status;
    end if;
    v_id := v_period.id;
    perform set_config('app.payroll_transition', 'on', true);
    update public.payroll_periods
      set note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note)
      where id = v_id;
    perform set_config('app.payroll_transition', 'off', true);
    delete from public.payroll_lines where period_id = v_id;
  else
    -- Two first-time prepares racing for the same range: the second one
    -- adopts the row the first created.
    insert into public.payroll_periods (company_id, period_start, period_end, currency, note)
      values (p_company_id, p_start, p_end, v_currency, p_note)
      on conflict (company_id, period_start, period_end, currency) do nothing
      returning id into v_id;
    if v_id is null then
      select id into v_id from public.payroll_periods
        where company_id = p_company_id and period_start = p_start and period_end = p_end and currency = v_currency
        for update;
      delete from public.payroll_lines where period_id = v_id;
    end if;
  end if;

  -- One line per approved record in force at any point of the period, in
  -- the period's currency, for employment that is not former (or ended
  -- inside the period).
  insert into public.payroll_lines
    (period_id, company_id, person_id, employment_period_id, compensation_record_id, full_name, job_title,
     amount, currency, pay_basis_key, effective_from, effective_to, days_covered)
  select v_id, p_company_id, ep.person_id, ep.id, c.id, p.full_name, ep.job_title,
         c.amount, c.currency, c.pay_basis_key,
         greatest(c.effective_date, p_start, ep.start_date) as effective_from,
         least(coalesce(c.end_date, p_end), p_end, coalesce(ep.end_date, p_end)) as effective_to,
         (least(coalesce(c.end_date, p_end), p_end, coalesce(ep.end_date, p_end))
            - greatest(c.effective_date, p_start, ep.start_date) + 1) as days_covered
  from public.compensation_records c
  join public.employment_periods ep on ep.id = c.employment_period_id
  join public.people p on p.id = ep.person_id
  where ep.company_id = p_company_id
    and c.status = 'approved'
    and c.currency = v_currency
    and c.effective_date <= p_end
    and c.effective_date <= coalesce(ep.end_date, p_end)   -- a raise dated after a later-set departure never pays
    and (c.end_date is null or c.end_date >= p_start)
    and ep.start_date <= p_end
    and (ep.end_date is null or ep.end_date >= p_start)
    and ep.status <> 'draft'
  order by p.full_name, c.effective_date;
  get diagnostics v_lines = row_count;

  select count(distinct ep.person_id) into v_uncovered
  from public.employment_periods ep
  where ep.company_id = p_company_id and ep.status = 'active'
    and ep.start_date <= p_end
    and not exists (select 1 from public.payroll_lines l where l.period_id = v_id and l.person_id = ep.person_id);

  perform set_config('app.payroll_transition', 'on', true);
  update public.payroll_periods
    set status = 'in_review', prepared_by = v_me, prepared_at = now(), approved_by = null
    where id = v_id;
  perform set_config('app.payroll_transition', 'off', true);
  return jsonb_build_object('period_id', v_id, 'lines', v_lines, 'uncovered', v_uncovered);
end $$;

create or replace function public.approve_payroll_period(p_period_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.payroll_periods where id = p_period_id for update;
  if not found then
    raise exception 'Payroll period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'payroll.approve') then
    raise exception 'Approving payroll needs payroll.approve in this company.' using errcode = '42501';
  end if;
  if v_period.status <> 'in_review' then
    raise exception 'Only a prepared period can be approved.';
  end if;
  if v_period.prepared_by is not distinct from v_me then
    raise exception 'The person who prepared a period cannot approve it.' using errcode = '42501';
  end if;
  perform set_config('app.payroll_transition', 'on', true);
  update public.payroll_periods set status = 'approved', approved_by = v_me where id = p_period_id;
  perform set_config('app.payroll_transition', 'off', true);
  return jsonb_build_object('status', 'approved');
end $$;

create or replace function public.reopen_payroll_period(p_period_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period record;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.payroll_periods where id = p_period_id for update;
  if not found then
    raise exception 'Payroll period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'payroll.approve') then
    raise exception 'Reopening payroll needs payroll.approve in this company.' using errcode = '42501';
  end if;
  if v_period.status <> 'approved' then
    raise exception 'Only an approved period can be reopened.';
  end if;
  perform set_config('app.payroll_transition', 'on', true);
  update public.payroll_periods set status = 'in_review', approved_by = null where id = p_period_id;
  perform set_config('app.payroll_transition', 'off', true);
  return jsonb_build_object('status', 'in_review');
end $$;

create or replace function public.mark_payroll_exported(p_period_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period record;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.payroll_periods where id = p_period_id for update;
  if not found then
    raise exception 'Payroll period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'payroll.export') then
    raise exception 'Exporting payroll needs payroll.export in this company.' using errcode = '42501';
  end if;
  if v_period.status <> 'approved' then
    raise exception 'Only an approved period can be exported.';
  end if;
  perform set_config('app.payroll_transition', 'on', true);
  update public.payroll_periods set status = 'exported', exported_at = now() where id = p_period_id;
  perform set_config('app.payroll_transition', 'off', true);
  return jsonb_build_object('status', 'exported');
end $$;

revoke all on function public.prepare_payroll_period(uuid, date, date, text, text) from public, anon;
revoke all on function public.approve_payroll_period(uuid) from public, anon;
revoke all on function public.reopen_payroll_period(uuid) from public, anon;
revoke all on function public.mark_payroll_exported(uuid) from public, anon;
grant execute on function public.prepare_payroll_period(uuid, date, date, text, text) to authenticated, service_role;
grant execute on function public.approve_payroll_period(uuid) to authenticated, service_role;
grant execute on function public.reopen_payroll_period(uuid) to authenticated, service_role;
grant execute on function public.mark_payroll_exported(uuid) to authenticated, service_role;

-- The lines carry amounts: audited without them.
create trigger audit after insert or update or delete on public.payroll_lines
  for each row execute function app.audit_redacted('amount');
