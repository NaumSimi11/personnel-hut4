-- 0027_leave.sql
-- Leave (plan 035): types, calendars, balances, requests and their state
-- machines, ported from Field Notebook's rules with two of its defects fixed
-- (pending requests count against what is requestable; approval re-checks
-- under a row lock). Balances are derived from approved requests and
-- signed adjustments — never a stored "remaining" that can drift.

-- ------------------------------------------------------------ capabilities
insert into public.capabilities (key, group_name, label, sensitive, sort_order) values
  ('leave.view',      'Leave', 'View team leave with types and balances', true, 10),
  ('leave.approve',   'Leave', 'Approve and cancel leave', false, 20),
  ('leave.adjust',    'Leave', 'Adjust balances and entitlements', true, 30),
  ('holidays.manage', 'Leave', 'Manage holiday calendars and closures', false, 40)
on conflict (key) do nothing;
insert into public.capability_dependencies (capability_key, requires_key) values
  ('leave.approve', 'leave.view'), ('leave.adjust', 'leave.view')
on conflict do nothing;
with caps(preset, cap) as (values
  ('Company HR', 'leave.view'), ('Company HR', 'leave.approve'), ('Company HR', 'leave.adjust'), ('Company HR', 'holidays.manage'),
  ('Holding HR', 'leave.view'), ('Holding HR', 'leave.approve'), ('Holding HR', 'leave.adjust'), ('Holding HR', 'holidays.manage'),
  ('Company Director', 'leave.view'), ('Company Director', 'leave.approve')
), p as (select id, name from public.permission_presets where company_id is null)
insert into public.preset_capabilities (preset_id, capability_key)
select p.id, caps.cap from caps join p on p.name = caps.preset
on conflict do nothing;

-- ------------------------------------------------------------------- types
create table public.leave_types (
  key text primary key,
  label text not null,
  deducts_balance boolean not null default false,
  requires_document boolean not null default false,
  is_active boolean not null default true,
  sort_order int not null default 0
);
insert into public.leave_types (key, label, deducts_balance, requires_document, sort_order) values
  ('annual', 'Annual leave', true, false, 10),
  ('sick', 'Sick leave', false, true, 20),
  ('unpaid', 'Unpaid leave', false, false, 30),
  ('justified_day', 'Justified day', false, false, 40),
  ('other', 'Other', false, false, 90);
alter table public.leave_types enable row level security;
create policy read_all on public.leave_types for select to authenticated using (true);
create policy admin_write on public.leave_types for all to authenticated using (app.is_admin()) with check (app.is_admin());
grant select on public.leave_types to authenticated;
grant all on public.leave_types to service_role;

insert into public.document_categories (key, label, person_scoped, sort_order) values
  ('medical_certificate', 'Medical certificate', true, 45)
on conflict (key) do nothing;

-- --------------------------------------------------------------- calendars
alter table public.companies
  add column country_code char(2),
  add column leave_entitlement_days int not null default 22 check (leave_entitlement_days between 0 and 100),
  -- MM-DD that exists every year (no 29 February).
  add column leave_carry_over_until text not null default '06-30'
    check (leave_carry_over_until ~ '^((0[13-9]|1[0-2])-(0[1-9]|[12]\d|30)|(0[13578]|1[02])-31|02-(0[1-9]|1\d|2[0-8]))$');

update public.companies set country_code = case
  when country ilike '%macedonia%' then 'MK' when country ilike 'serbia%' then 'RS' when country ilike 'malta%' then 'MT'
  else country_code end
  where country_code is null and country is not null;

create table public.public_holidays (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null,
  date date not null,
  name text not null,
  kind text not null default 'statutory' check (kind in ('statutory', 'other')),
  observed_of date,                      -- the commemorated date when this is the substitute day
  created_at timestamptz not null default now(),
  unique (country_code, date)
);
create table public.company_closures (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  date date not null,
  name text not null,
  created_at timestamptz not null default now(),
  unique (company_id, date)
);
alter table public.public_holidays enable row level security;
alter table public.company_closures enable row level security;
create policy read_all on public.public_holidays for select to authenticated using (true);
create policy write on public.public_holidays for all to authenticated
  using (app.is_admin() or app.has_capability_anywhere('holidays.manage'))
  with check (app.is_admin() or app.has_capability_anywhere('holidays.manage'));
create policy sel on public.company_closures for select to authenticated using (app.in_company(company_id));
create policy write on public.company_closures for all to authenticated
  using (app.has_capability(company_id, 'holidays.manage'))
  with check (app.has_capability(company_id, 'holidays.manage'));
grant select, insert, update, delete on public.public_holidays, public.company_closures to authenticated;
grant all on public.public_holidays, public.company_closures to service_role;

-- The calendar an employment follows: its location's country, else the company's.
create or replace function app.employment_country(p_period_id uuid) returns char(2)
language sql stable security definer set search_path = public as $$
  select coalesce(l.country_code, c.country_code)
  from public.employment_periods ep
  join public.companies c on c.id = ep.company_id
  left join public.locations l on l.id = ep.location_id
  where ep.id = p_period_id
$$;

-- Weekends, the country's holidays and the company's closures are not working days.
create or replace function app.working_days(p_start date, p_end date, p_country char(2), p_company_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int
  from generate_series(p_start, p_end, interval '1 day') d
  where extract(isodow from d) < 6
    and not exists (select 1 from public.public_holidays h where h.country_code = p_country and h.date = d::date)
    and not exists (select 1 from public.company_closures cc where cc.company_id = p_company_id and cc.date = d::date)
$$;
grant execute on function app.working_days(date, date, char, uuid) to authenticated;
grant execute on function app.employment_country(uuid) to authenticated;

-- ---------------------------------------------------------------- balances
create table public.leave_balances (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id),
  company_id uuid not null references public.companies(id),
  year int not null check (year between 2000 and 2100),
  entitlement_days numeric(6,2) not null default 0 check (entitlement_days >= 0),
  carry_over_days numeric(6,2) not null default 0 check (carry_over_days >= 0),
  carry_over_expires_on date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (person_id, company_id, year)
);
create trigger touch before update on public.leave_balances for each row execute function app.touch_updated_at();

create table public.leave_adjustments (
  id uuid primary key default gen_random_uuid(),
  balance_id uuid not null references public.leave_balances(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  days numeric(6,2) not null,
  kind text not null check (kind in ('manual', 'entitlement_change', 'import', 'correction')),
  reason text not null,
  created_by uuid references public.people(id),
  created_at timestamptz not null default now()
);
create index leave_adjustments_balance_idx on public.leave_adjustments (balance_id);

-- ---------------------------------------------------------------- requests
create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id),
  employment_period_id uuid not null references public.employment_periods(id),
  company_id uuid not null references public.companies(id),
  leave_type_key text not null references public.leave_types(key),
  deducts_balance boolean not null,            -- snapshot of the type at filing
  requires_document boolean not null,          -- snapshot of the type at filing
  start_date date not null,
  end_date date not null check (end_date >= start_date),
  working_days int not null check (working_days >= 0),
  carry_over_days_used int not null default 0,
  note text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  documents_to_follow boolean not null default false,
  submitted_by uuid references public.people(id),
  decided_by uuid references public.people(id),
  decided_at timestamptz,
  decision_note text,
  cancelled_by uuid references public.people(id),
  cancelled_at timestamptz,
  cancellation_reason text,
  cancellation_requested_at timestamptz,
  cancellation_request_reason text,
  cancellation_declined_at timestamptz,
  cancellation_declined_by uuid references public.people(id),
  cancellation_decline_note text,
  legacy_id int unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index leave_requests_person_idx on public.leave_requests (person_id, start_date);
create index leave_requests_company_dates_idx on public.leave_requests (company_id, start_date, end_date);
create trigger touch before update on public.leave_requests for each row execute function app.touch_updated_at();

create table public.leave_request_documents (
  request_id uuid not null references public.leave_requests(id) on delete cascade,
  document_id uuid not null references public.documents(id) on delete cascade,
  primary key (request_id, document_id)
);

-- ------------------------------------------------------------------- RLS
alter table public.leave_balances enable row level security;
alter table public.leave_adjustments enable row level security;
alter table public.leave_requests enable row level security;
alter table public.leave_request_documents enable row level security;
create policy sel on public.leave_balances for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'leave.view'));
create policy sel on public.leave_adjustments for select to authenticated
  using (app.has_capability(company_id, 'leave.view')
         or exists (select 1 from public.leave_balances b where b.id = balance_id and app.is_self(b.person_id)));
create policy sel on public.leave_requests for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'leave.view') or app.has_capability(company_id, 'leave.approve'));
create policy sel on public.leave_request_documents for select to authenticated
  using (exists (select 1 from public.leave_requests r where r.id = request_id
                 and (app.is_self(r.person_id) or app.has_capability(r.company_id, 'leave.view'))));
grant select on public.leave_balances, public.leave_adjustments, public.leave_requests, public.leave_request_documents to authenticated;
grant all on public.leave_balances, public.leave_adjustments, public.leave_requests, public.leave_request_documents to service_role;

create trigger audit after insert or update or delete on public.leave_requests for each row execute function app.audit_redacted('note,cancellation_request_reason,cancellation_decline_note,decision_note');
create trigger audit after insert or update or delete on public.leave_balances for each row execute function app.audit();
create trigger audit after insert or update or delete on public.leave_adjustments for each row execute function app.audit();

-- ------------------------------------------------------------ balance math
-- Carry-over expiry for a year in a company: '06-30' → 30 June of that year.
create or replace function app.carry_over_expiry(p_company_id uuid, p_year int) returns date
language sql stable security definer set search_path = public as $$
  select to_date(p_year::text || '-' || c.leave_carry_over_until, 'YYYY-MM-DD') from public.companies c where c.id = p_company_id
$$;

-- Working days of a range that fall inside the carry-over window of the year.
create or replace function app.carry_over_eligible_days(p_start date, p_end date, p_country char(2), p_company_id uuid, p_year int) returns int
language plpgsql stable security definer set search_path = public as $$
declare
  v_from date := make_date(p_year, 1, 1);
  v_to date := app.carry_over_expiry(p_company_id, p_year);
begin
  if p_end < v_from or p_start > v_to then return 0; end if;
  return app.working_days(greatest(p_start, v_from), least(p_end, v_to), p_country, p_company_id);
end $$;

-- The whole picture for one person, company and year.
create or replace function public.leave_balance(p_person_id uuid, p_company_id uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_b record;
  v_used numeric := 0;
  v_co_used numeric := 0;
  v_pending numeric := 0;
  v_expired boolean;
begin
  if auth.uid() is not null and not (app.is_self(p_person_id) or app.has_capability(p_company_id, 'leave.view')
                                     or app.has_capability(p_company_id, 'leave.adjust')) then
    raise exception 'Viewing this balance needs leave.view in the company.' using errcode = '42501';
  end if;
  select * into v_b from public.leave_balances where person_id = p_person_id and company_id = p_company_id and year = p_year;
  if not found then
    return jsonb_build_object('exists', false, 'year', p_year, 'entitlement', 0, 'carry_over', 0, 'adjustments', 0,
      'used', 0, 'carry_over_used', 0, 'pending', 0, 'remaining', 0, 'carry_over_remaining', 0, 'carry_over_expires_on', null);
  end if;
  select coalesce(sum(working_days - carry_over_days_used), 0), coalesce(sum(carry_over_days_used), 0)
    into v_used, v_co_used
    from public.leave_requests r
    where r.person_id = p_person_id and r.company_id = p_company_id and r.status = 'approved'
      and r.deducts_balance and extract(year from r.start_date) = p_year;
  select coalesce(sum(working_days), 0) into v_pending
    from public.leave_requests r
    where r.person_id = p_person_id and r.company_id = p_company_id and r.status = 'pending'
      and r.deducts_balance and extract(year from r.start_date) = p_year;
  v_expired := v_b.carry_over_expires_on is not null and v_b.carry_over_expires_on < current_date;
  return jsonb_build_object(
    'exists', true, 'year', p_year,
    'entitlement', v_b.entitlement_days,
    'carry_over', v_b.carry_over_days,
    'carry_over_expires_on', v_b.carry_over_expires_on,
    'carry_over_expired', v_expired,
    'adjustments', (select coalesce(sum(days), 0) from public.leave_adjustments a where a.balance_id = v_b.id),
    'used', v_used,
    'carry_over_used', v_co_used,
    'pending', v_pending,
    'remaining', v_b.entitlement_days + (select coalesce(sum(days), 0) from public.leave_adjustments a where a.balance_id = v_b.id) - v_used,
    'carry_over_remaining', case when v_expired then 0 else v_b.carry_over_days - v_co_used end
  );
end $$;
grant execute on function public.leave_balance(uuid, uuid, int) to authenticated, service_role;

-- What a request over these dates could still draw: entitlement remaining
-- minus pending requests, plus whatever carry-over fits inside its window.
create or replace function app.requestable_leave(p_person_id uuid, p_company_id uuid, p_start date, p_end date, p_country char(2)) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_year int := extract(year from p_start);
  v_b record;
  v_used numeric; v_co_used numeric; v_pending numeric; v_pending_co numeric; v_adj numeric;
  v_entitlement_left numeric; v_co_left numeric;
begin
  select * into v_b from public.leave_balances where person_id = p_person_id and company_id = p_company_id and year = v_year;
  if not found then return 0; end if;
  select coalesce(sum(working_days - carry_over_days_used), 0), coalesce(sum(carry_over_days_used), 0) into v_used, v_co_used
    from public.leave_requests r where r.person_id = p_person_id and r.company_id = p_company_id and r.status = 'approved'
      and r.deducts_balance and extract(year from r.start_date) = v_year;
  -- Pending requests are promises: they reserve what they would take.
  select coalesce(sum(working_days), 0) into v_pending
    from public.leave_requests r where r.person_id = p_person_id and r.company_id = p_company_id and r.status = 'pending'
      and r.deducts_balance and extract(year from r.start_date) = v_year;
  select coalesce(sum(days), 0) into v_adj from public.leave_adjustments a where a.balance_id = v_b.id;
  v_entitlement_left := greatest(0, v_b.entitlement_days + v_adj - v_used - v_pending);
  -- Carry-over is limited by the requested dates (the window), never by today.
  v_co_left := greatest(0, v_b.carry_over_days - v_co_used);
  return v_entitlement_left + least(v_co_left, app.carry_over_eligible_days(p_start, p_end, p_country, p_company_id, v_year));
end $$;

-- -------------------------------------------------------------- functions
create or replace function public.request_leave(
  p_person_id uuid,
  p_leave_type_key text,
  p_start date,
  p_end date,
  p_note text default null,
  p_documents_to_follow boolean default false,
  p_record_as_approved boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period record;
  v_type record;
  v_country char(2);
  v_days int;
  v_id uuid;
  v_approver boolean;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'The end date must not be before the start date.';
  end if;
  -- One filing at a time per person: the overlap and balance checks below
  -- are only meaningful if two submissions cannot interleave.
  perform pg_advisory_xact_lock(hashtext('leave:' || p_person_id::text));
  -- The employment the leave belongs to: the one current on the start date.
  select ep.* into v_period from public.employment_periods ep
    join public.employment_statuses es on es.key = ep.status
    where ep.person_id = p_person_id and es.counts_as_employed
      and ep.start_date <= p_end and (ep.end_date is null or ep.end_date >= p_start)
    order by ep.start_date desc limit 1;
  if not found then
    raise exception 'No current employment covers those dates.';
  end if;
  v_approver := app.has_capability(v_period.company_id, 'leave.approve');
  if p_person_id <> v_me and not v_approver then
    raise exception 'You can only request leave for yourself.' using errcode = '42501';
  end if;
  select * into v_type from public.leave_types where key = p_leave_type_key and is_active;
  if not found then
    raise exception 'Choose the kind of leave.';
  end if;
  if v_type.requires_document and not p_documents_to_follow then
    raise exception 'This kind of leave needs a supporting document: attach one after filing, or confirm one will follow.';
  end if;
  if v_type.deducts_balance and extract(year from p_start) <> extract(year from p_end) then
    raise exception 'Annual leave is requested per leave year: split it at 31 December.';
  end if;
  v_country := app.employment_country(v_period.id);
  if v_country is null then
    raise exception 'The company (or the person''s location) has no country yet, so holidays cannot be excluded. Set it first.';
  end if;
  v_days := app.working_days(p_start, p_end, v_country, v_period.company_id);
  if v_days = 0 then
    raise exception 'Those dates contain no working days (weekends and holidays are not deducted).';
  end if;
  if v_type.deducts_balance and v_days > app.requestable_leave(p_person_id, v_period.company_id, p_start, p_end, v_country) then
    raise exception 'Not enough annual leave left for those dates (pending requests count too).';
  end if;
  if exists (select 1 from public.leave_requests r where r.person_id = p_person_id and r.status in ('pending', 'approved')
             and r.start_date <= p_end and r.end_date >= p_start) then
    raise exception 'Leave is already requested or approved for some of those dates.';
  end if;
  insert into public.leave_requests
      (person_id, employment_period_id, company_id, leave_type_key, deducts_balance, requires_document,
       start_date, end_date, working_days, note, documents_to_follow, submitted_by)
    values (p_person_id, v_period.id, v_period.company_id, v_type.key, v_type.deducts_balance, v_type.requires_document,
            p_start, p_end, v_days, nullif(trim(coalesce(p_note, '')), ''), v_type.requires_document and p_documents_to_follow, v_me)
    returning id into v_id;
  -- Recording something already agreed: an approver files and approves in
  -- one step, but never for their own leave.
  if p_record_as_approved and v_approver and p_person_id <> v_me then
    perform public.decide_leave(v_id, 'approved', null);
  end if;
  return jsonb_build_object('request_id', v_id, 'working_days', v_days,
    'status', (select status from public.leave_requests where id = v_id));
end $$;

create or replace function public.decide_leave(p_request_id uuid, p_decision text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
  v_b record;
  v_country char(2);
  v_year int;
  v_co_used int := 0;
  v_left numeric;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Unknown decision: %', p_decision;
  end if;
  select * into v_r from public.leave_requests where id = p_request_id for update;
  if not found then
    raise exception 'Leave request not found.';
  end if;
  if not app.has_capability(v_r.company_id, 'leave.approve') then
    raise exception 'Deciding leave needs leave.approve in this company.' using errcode = '42501';
  end if;
  if v_r.person_id = v_me then
    raise exception 'You cannot decide your own leave.' using errcode = '42501';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'Only a pending request can be decided.';
  end if;
  if p_decision = 'approved' and exists (select 1 from public.leave_requests x where x.person_id = v_r.person_id and x.id <> v_r.id
        and x.status = 'approved' and x.start_date <= v_r.end_date and x.end_date >= v_r.start_date) then
    raise exception 'Approved leave already covers some of those dates.';
  end if;
  if p_decision = 'rejected' then
    update public.leave_requests set status = 'rejected', decided_by = v_me, decided_at = now(),
      decision_note = nullif(trim(coalesce(p_note, '')), '') where id = p_request_id;
    return jsonb_build_object('status', 'rejected');
  end if;
  if v_r.deducts_balance then
    v_year := extract(year from v_r.start_date);
    -- Lock the balance so two approvals cannot both pass the check.
    select * into v_b from public.leave_balances
      where person_id = v_r.person_id and company_id = v_r.company_id and year = v_year for update;
    if not found then
      raise exception 'No leave balance exists for % yet; set the entitlement first.', v_year;
    end if;
    v_country := app.employment_country(v_r.employment_period_id);
    -- Carry-over first, for the days inside its window; the rest from the year.
    -- Carry-over first, limited by the window the requested dates fall in
    -- (never by today), in whole days.
    v_co_used := floor(least(
      greatest(0, v_b.carry_over_days - (select coalesce(sum(carry_over_days_used), 0) from public.leave_requests x
                 where x.person_id = v_r.person_id and x.company_id = v_r.company_id and x.status = 'approved' and x.deducts_balance
                   and extract(year from x.start_date) = v_year)),
      app.carry_over_eligible_days(v_r.start_date, v_r.end_date, v_country, v_r.company_id, v_year),
      v_r.working_days))::int;
    v_left := v_b.entitlement_days
      + (select coalesce(sum(days), 0) from public.leave_adjustments a where a.balance_id = v_b.id)
      - (select coalesce(sum(working_days - carry_over_days_used), 0) from public.leave_requests x
           where x.person_id = v_r.person_id and x.company_id = v_r.company_id and x.status = 'approved' and x.deducts_balance
             and extract(year from x.start_date) = v_year);
    if v_r.working_days - v_co_used > v_left then
      raise exception 'Not enough annual leave left: % day(s) remain, this request needs % from the year.', v_left, v_r.working_days - v_co_used;
    end if;
  end if;
  update public.leave_requests
    set status = 'approved', decided_by = v_me, decided_at = now(), carry_over_days_used = v_co_used,
        decision_note = nullif(trim(coalesce(p_note, '')), '')
    where id = p_request_id;
  return jsonb_build_object('status', 'approved', 'carry_over_days_used', v_co_used);
end $$;

-- The owner cancels before it starts; an approver cancels any time (the ask
-- from the owner, if any, is answered by the cancellation). A reason is required.
create or replace function public.cancel_leave(p_request_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Say why the leave is cancelled.';
  end if;
  select * into v_r from public.leave_requests where id = p_request_id for update;
  if not found then
    raise exception 'Leave request not found.';
  end if;
  if v_r.status not in ('pending', 'approved') then
    raise exception 'Only pending or approved leave can be cancelled.';
  end if;
  if not app.has_capability(v_r.company_id, 'leave.approve') then
    if v_r.person_id <> v_me then
      raise exception 'Only the person or an approver can cancel this leave.' using errcode = '42501';
    end if;
    if v_r.start_date <= current_date then
      raise exception 'This leave has started; ask HR to cancel it and say why.';
    end if;
  end if;
  update public.leave_requests
    set status = 'cancelled', cancelled_by = v_me, cancelled_at = now(), cancellation_reason = trim(p_reason)
    where id = p_request_id;
  return jsonb_build_object('status', 'cancelled');
end $$;

create or replace function public.request_leave_cancellation(p_request_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Say why the leave should be cancelled.';
  end if;
  select * into v_r from public.leave_requests where id = p_request_id for update;
  if not found or v_r.person_id <> v_me then
    raise exception 'Leave request not found.';
  end if;
  if v_r.status not in ('pending', 'approved') then
    raise exception 'Only pending or approved leave can be cancelled.';
  end if;
  update public.leave_requests
    set cancellation_requested_at = now(), cancellation_request_reason = trim(p_reason),
        cancellation_declined_at = null, cancellation_declined_by = null, cancellation_decline_note = null
    where id = p_request_id;
  return jsonb_build_object('status', 'asked');
end $$;

create or replace function public.decline_leave_cancellation(p_request_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_r from public.leave_requests where id = p_request_id for update;
  if not found then
    raise exception 'Leave request not found.';
  end if;
  if not app.has_capability(v_r.company_id, 'leave.approve') then
    raise exception 'Declining needs leave.approve in this company.' using errcode = '42501';
  end if;
  if v_r.cancellation_requested_at is null then
    raise exception 'There is no cancellation ask on this leave.';
  end if;
  update public.leave_requests
    set cancellation_declined_at = now(), cancellation_declined_by = v_me,
        cancellation_decline_note = nullif(trim(coalesce(p_note, '')), '')
    where id = p_request_id;
  return jsonb_build_object('status', 'declined');
end $$;

-- A document (already uploaded as a person document) is attached to a
-- request by the person or an approver; a promise made at filing is kept.
create or replace function public.attach_leave_document(p_request_id uuid, p_document_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
  v_d record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_r from public.leave_requests where id = p_request_id for update;
  if not found then
    raise exception 'Leave request not found.';
  end if;
  if v_r.person_id <> v_me and not app.has_capability(v_r.company_id, 'leave.approve') then
    raise exception 'Only the person or an approver can attach documents.' using errcode = '42501';
  end if;
  select * into v_d from public.documents where id = p_document_id;
  if not found or v_d.person_id is distinct from v_r.person_id or v_d.archived_at is not null then
    raise exception 'The document must be one of this person''s live documents.';
  end if;
  insert into public.leave_request_documents (request_id, document_id) values (p_request_id, p_document_id)
    on conflict do nothing;
  update public.leave_requests set documents_to_follow = false where id = p_request_id;
  return jsonb_build_object('attached', true);
end $$;

-- ------------------------------------------------ balances: set and adjust
create or replace function public.set_leave_entitlement(p_person_id uuid, p_company_id uuid, p_year int, p_entitlement numeric, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_b record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'leave.adjust') then
    raise exception 'Changing entitlements needs leave.adjust in this company.' using errcode = '42501';
  end if;
  if p_entitlement is null or p_entitlement < 0 or p_entitlement > 100 then
    raise exception 'Enter the yearly entitlement in days.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Say why the entitlement changes.';
  end if;
  if not exists (select 1 from public.employment_periods ep where ep.person_id = p_person_id and ep.company_id = p_company_id) then
    raise exception 'This person has no employment in that company.';
  end if;
  select * into v_b from public.leave_balances where person_id = p_person_id and company_id = p_company_id and year = p_year for update;
  if not found then
    insert into public.leave_balances (person_id, company_id, year, entitlement_days, carry_over_expires_on)
      values (p_person_id, p_company_id, p_year, p_entitlement, app.carry_over_expiry(p_company_id, p_year))
      returning * into v_b;
    insert into public.leave_adjustments (balance_id, company_id, days, kind, reason, created_by)
      values (v_b.id, p_company_id, 0, 'entitlement_change', trim(p_reason), v_me);
  else
    update public.leave_balances set entitlement_days = p_entitlement where id = v_b.id;
    insert into public.leave_adjustments (balance_id, company_id, days, kind, reason, created_by)
      values (v_b.id, p_company_id, 0, 'entitlement_change', trim(p_reason) || ' (' || v_b.entitlement_days || ' → ' || p_entitlement || ')', v_me);
  end if;
  return jsonb_build_object('balance_id', v_b.id);
end $$;

create or replace function public.adjust_leave_balance(p_person_id uuid, p_company_id uuid, p_year int, p_days numeric, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_b record;
  v_remaining numeric;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'leave.adjust') then
    raise exception 'Adjusting balances needs leave.adjust in this company.' using errcode = '42501';
  end if;
  if p_days is null or p_days = 0 then
    raise exception 'Enter the days to add (positive) or remove (negative).';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Say why the balance changes.';
  end if;
  select * into v_b from public.leave_balances where person_id = p_person_id and company_id = p_company_id and year = p_year for update;
  if not found then
    raise exception 'No leave balance exists for % yet; set the entitlement first.', p_year;
  end if;
  v_remaining := (public.leave_balance(p_person_id, p_company_id, p_year)->>'remaining')::numeric;
  if v_remaining + p_days < 0 then
    raise exception 'That would take the balance below zero (% remaining).', v_remaining;
  end if;
  insert into public.leave_adjustments (balance_id, company_id, days, kind, reason, created_by)
    values (v_b.id, p_company_id, p_days, 'manual', trim(p_reason), v_me);
  return jsonb_build_object('remaining', v_remaining + p_days);
end $$;

-- --------------------------------------------------------------- rollover
-- Next year's balance for every current employment: the company's default
-- entitlement (or the person's, if their previous year had one), and what
-- was left carried over until the company's expiry date. Idempotent.
create or replace function public.roll_leave_year(p_year int) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_ep record;
  v_prev jsonb;
  v_n int := 0;
  v_entitlement numeric;
  v_carry numeric;
begin
  if auth.uid() is not null and not app.is_admin() then
    raise exception 'Rolling the leave year needs platform admin access.' using errcode = '42501';
  end if;
  for v_ep in
    select distinct on (ep.person_id, ep.company_id) ep.person_id, ep.company_id, c.leave_entitlement_days
    from public.employment_periods ep join public.companies c on c.id = ep.company_id
    join public.employment_statuses es on es.key = ep.status
    where es.counts_as_employed and ep.start_date <= make_date(p_year, 12, 31)
      and (ep.end_date is null or ep.end_date >= make_date(p_year, 1, 1))
    order by ep.person_id, ep.company_id, ep.start_date desc
  loop
    if exists (select 1 from public.leave_balances b where b.person_id = v_ep.person_id and b.company_id = v_ep.company_id and b.year = p_year) then
      continue;
    end if;
    v_entitlement := coalesce((select entitlement_days from public.leave_balances b
      where b.person_id = v_ep.person_id and b.company_id = v_ep.company_id and b.year = p_year - 1), v_ep.leave_entitlement_days);
    v_prev := case when exists (select 1 from public.leave_balances b where b.person_id = v_ep.person_id and b.company_id = v_ep.company_id and b.year = p_year - 1)
                   then public.leave_balance(v_ep.person_id, v_ep.company_id, p_year - 1) else null end;
    -- What is left of the year (pending requests count as taken, so a
    -- December request approved in January is never double-counted), plus
    -- the previous carry-over only if its window ran to the end of the year.
    v_carry := greatest(0, coalesce((v_prev->>'remaining')::numeric, 0) - coalesce((v_prev->>'pending')::numeric, 0))
      + case when (v_prev->>'carry_over_expires_on')::date >= make_date(p_year - 1, 12, 31)
             then greatest(0, coalesce((v_prev->>'carry_over')::numeric, 0) - coalesce((v_prev->>'carry_over_used')::numeric, 0)) else 0 end;
    insert into public.leave_balances (person_id, company_id, year, entitlement_days, carry_over_days, carry_over_expires_on)
      values (v_ep.person_id, v_ep.company_id, p_year, v_entitlement, v_carry, app.carry_over_expiry(v_ep.company_id, p_year));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ------------------------------------------------------------- team view
-- Everyone in the company sees who is away; only the person and leave.view
-- holders see what kind, notes or asks. Redaction is done here, never in
-- the client.
create or replace function public.team_leave(p_company_id uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_full boolean;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.in_company(p_company_id) and not app.has_capability(p_company_id, 'leave.view') then
    raise exception 'You are not in this company.' using errcode = '42501';
  end if;
  v_full := app.has_capability(p_company_id, 'leave.view') or app.has_capability(p_company_id, 'leave.approve');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id,
      'person_id', r.person_id,
      'full_name', p.full_name,
      'start_date', r.start_date,
      'end_date', r.end_date,
      'working_days', r.working_days,
      'status', r.status,
      'leave_type_key', case when v_full or r.person_id = v_me then r.leave_type_key else 'away' end,
      'note', case when v_full or r.person_id = v_me then r.note else null end,
      'cancellation_asked', case when v_full or r.person_id = v_me
        then r.cancellation_requested_at is not null and r.status in ('pending', 'approved')
             and (r.cancellation_declined_at is null or r.cancellation_declined_at < r.cancellation_requested_at)
        else false end
    ) order by r.start_date, p.full_name)
    from public.leave_requests r join public.people p on p.id = r.person_id
    where r.company_id = p_company_id and r.status in ('pending', 'approved')
      and r.start_date <= p_to and r.end_date >= p_from), '[]'::jsonb);
end $$;

revoke all on function public.request_leave(uuid, text, date, date, text, boolean, boolean) from public, anon;
revoke all on function public.decide_leave(uuid, text, text) from public, anon;
revoke all on function public.cancel_leave(uuid, text) from public, anon;
revoke all on function public.request_leave_cancellation(uuid, text) from public, anon;
revoke all on function public.decline_leave_cancellation(uuid, text) from public, anon;
revoke all on function public.attach_leave_document(uuid, uuid) from public, anon;
revoke all on function public.set_leave_entitlement(uuid, uuid, int, numeric, text) from public, anon;
revoke all on function public.adjust_leave_balance(uuid, uuid, int, numeric, text) from public, anon;
revoke all on function public.roll_leave_year(int) from public, anon;
revoke all on function public.team_leave(uuid, date, date) from public, anon;
grant execute on function public.request_leave(uuid, text, date, date, text, boolean, boolean) to authenticated, service_role;
grant execute on function public.decide_leave(uuid, text, text) to authenticated, service_role;
grant execute on function public.cancel_leave(uuid, text) to authenticated, service_role;
grant execute on function public.request_leave_cancellation(uuid, text) to authenticated, service_role;
grant execute on function public.decline_leave_cancellation(uuid, text) to authenticated, service_role;
grant execute on function public.attach_leave_document(uuid, uuid) to authenticated, service_role;
grant execute on function public.set_leave_entitlement(uuid, uuid, int, numeric, text) to authenticated, service_role;
grant execute on function public.adjust_leave_balance(uuid, uuid, int, numeric, text) to authenticated, service_role;
grant execute on function public.roll_leave_year(int) to authenticated, service_role;
grant execute on function public.team_leave(uuid, date, date) to authenticated, service_role;

-- The rollover runs on 1 January, as the system (auth.uid() is null).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'roll-leave-year';
    perform cron.schedule('roll-leave-year', '30 0 1 1 *',
      $job$ select public.roll_leave_year(extract(year from current_date)::int) $job$);
  end if;
end $$;
