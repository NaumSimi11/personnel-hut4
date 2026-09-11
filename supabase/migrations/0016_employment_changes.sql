-- 0016_employment_changes.sql
-- Employment changes as dated events (plan 022, core plan §2): a change to
-- title, department, location, manager or employment type carries an
-- effective date and a reason. A change dated today or earlier applies at
-- once; a future one waits and never overwrites today's record. Circular
-- reporting is refused, and departments/locations must belong to the
-- company (or be shared holding defaults).

create table public.employment_changes (
  id uuid primary key default gen_random_uuid(),
  employment_period_id uuid not null references public.employment_periods(id) on delete cascade,
  company_id uuid not null references public.companies(id),  -- derived
  effective_date date not null,
  changes jsonb not null check (jsonb_typeof(changes) = 'object'),
  reason text,
  status text not null default 'scheduled' check (status in ('scheduled', 'applied', 'cancelled', 'failed')),
  failure_reason text,
  created_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  applied_at timestamptz
);
create index employment_changes_period_idx on public.employment_changes (employment_period_id);
create index employment_changes_due_idx on public.employment_changes (effective_date) where status = 'scheduled';
create trigger audit after insert or update or delete on public.employment_changes
  for each row execute function app.audit();

alter table public.employment_changes enable row level security;
-- Read with the directory; every write goes through the functions below.
create policy sel on public.employment_changes for select to authenticated
  using (app.has_capability(company_id, 'people.view'));
grant select on public.employment_changes to authenticated;
grant all on public.employment_changes to service_role;

-- --------------------------------------------------------------- guards
-- Would making `manager` the manager of `person` create a loop? Walk up the
-- manager chain from `manager` through current employment periods.
create or replace function app.would_create_cycle(person uuid, manager uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_cursor uuid := manager;
  v_hops int := 0;
begin
  if manager is null then return false; end if;
  if manager = person then return true; end if;
  while v_cursor is not null and v_hops < 50 loop
    select ep.manager_id into v_cursor
      from public.employment_periods ep
      where ep.person_id = v_cursor and ep.status <> 'former'
      order by ep.start_date desc
      limit 1;
    if v_cursor = person then return true; end if;
    v_hops := v_hops + 1;
  end loop;
  return false;
end $$;

-- Apply one change's fields to its period. Shared by immediate and due paths.
-- The world may have moved since scheduling, so the guards run again here;
-- a change that no longer fits is marked failed with the reason, never
-- applied, and never allowed to stall the others.
create or replace function app.apply_employment_change(change_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_change record;
  v_period record;
  v_manager uuid;
begin
  select * into v_change from public.employment_changes where id = change_id for update;
  if not found or v_change.status <> 'scheduled' then return false; end if;
  select * into v_period from public.employment_periods where id = v_change.employment_period_id for update;
  if not found or v_period.status = 'former' then
    update public.employment_changes set status = 'failed', failure_reason = 'The employment ended before the change applied.'
      where id = change_id;
    return false;
  end if;
  v_manager := nullif(v_change.changes->>'manager_id', '')::uuid;
  if v_manager is not null and app.would_create_cycle(v_period.person_id, v_manager) then
    update public.employment_changes set status = 'failed',
      failure_reason = 'Applying this would create a circular reporting line.'
      where id = change_id;
    return false;
  end if;
  begin
  update public.employment_periods set
    job_title = coalesce(v_change.changes->>'job_title', job_title),
    department_id = case when v_change.changes ? 'department_id'
                         then nullif(v_change.changes->>'department_id', '')::uuid else department_id end,
    location_id = case when v_change.changes ? 'location_id'
                       then nullif(v_change.changes->>'location_id', '')::uuid else location_id end,
    manager_id = case when v_change.changes ? 'manager_id'
                      then nullif(v_change.changes->>'manager_id', '')::uuid else manager_id end,
    employment_type_key = coalesce(nullif(v_change.changes->>'employment_type_key', ''), employment_type_key)
    where id = v_change.employment_period_id;
  exception when others then
    update public.employment_changes set status = 'failed', failure_reason = sqlerrm where id = change_id;
    return false;
  end;
  update public.employment_changes set status = 'applied', applied_at = now() where id = change_id;
  return true;
end $$;

-- ---------------------------------------------------------- schedule
create or replace function public.schedule_employment_change(
  p_period_id uuid,
  p_effective_date date,
  p_changes jsonb,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period record;
  v_change_id uuid;
  v_dept_company uuid;
  v_loc_company uuid;
  v_manager uuid;
  v_key text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'Employment period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'employment.edit') then
    raise exception 'Changing employment requires employment.edit in this company.' using errcode = '42501';
  end if;
  if v_period.status = 'former' then
    raise exception 'This employment has ended; add a new period instead.';
  end if;
  if p_effective_date is null then
    raise exception 'Choose the effective date.';
  end if;
  if p_effective_date < v_period.start_date then
    raise exception 'The effective date cannot be before the employment started.';
  end if;
  if v_period.end_date is not null and p_effective_date > v_period.end_date then
    raise exception 'The effective date is after the employment ends.';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'Nothing to change.';
  end if;
  for v_key in select jsonb_object_keys(p_changes) loop
    if v_key not in ('job_title', 'department_id', 'location_id', 'manager_id', 'employment_type_key') then
      raise exception 'Unknown field: %', v_key;
    end if;
  end loop;
  if p_changes ? 'job_title' and length(trim(coalesce(p_changes->>'job_title', ''))) < 2 then
    raise exception 'Enter the job title.';
  end if;

  if nullif(p_changes->>'department_id', '') is not null then
    select company_id into v_dept_company from public.departments
      where id = (p_changes->>'department_id')::uuid and archived_at is null;
    if not found then raise exception 'Department not found.'; end if;
    if v_dept_company is not null and v_dept_company <> v_period.company_id then
      raise exception 'That department belongs to another company.';
    end if;
  end if;
  if nullif(p_changes->>'location_id', '') is not null then
    select company_id into v_loc_company from public.locations
      where id = (p_changes->>'location_id')::uuid and archived_at is null;
    if not found then raise exception 'Location not found.'; end if;
    if v_loc_company is not null and v_loc_company <> v_period.company_id then
      raise exception 'That location belongs to another company.';
    end if;
  end if;
  if p_changes ? 'employment_type_key' then
    if nullif(p_changes->>'employment_type_key', '') is null then
      raise exception 'Choose the employment type.';
    end if;
    if not exists (select 1 from public.employment_types
                   where key = p_changes->>'employment_type_key' and archived_at is null) then
      raise exception 'Employment type not found.';
    end if;
  end if;
  v_manager := nullif(p_changes->>'manager_id', '')::uuid;
  if v_manager is not null then
    if not exists (select 1 from public.people where id = v_manager and archived_at is null) then
      raise exception 'Manager not found.';
    end if;
    if v_manager = v_period.person_id then
      raise exception 'A person cannot be their own manager.';
    end if;
    if app.would_create_cycle(v_period.person_id, v_manager) then
      raise exception 'That would create a circular reporting line: the proposed manager already reports to this person.';
    end if;
  end if;

  insert into public.employment_changes
      (employment_period_id, company_id, effective_date, changes, reason, created_by)
    values (p_period_id, v_period.company_id, p_effective_date, p_changes, nullif(trim(coalesce(p_reason, '')), ''), v_me)
    returning id into v_change_id;

  if p_effective_date <= current_date then
    if not app.apply_employment_change(v_change_id) then
      raise exception '%', coalesce((select failure_reason from public.employment_changes where id = v_change_id), 'The change could not be applied.');
    end if;
    return jsonb_build_object('change_id', v_change_id, 'applied', true);
  end if;
  return jsonb_build_object('change_id', v_change_id, 'applied', false);
end $$;

-- ------------------------------------------------------------- apply due
-- Idempotent: anyone signed in may trigger it (the app does on load); a
-- scheduler can call it too. Applies in date order.
create or replace function public.apply_due_employment_changes() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_n int := 0;
begin
  for v_id in
    select id from public.employment_changes
    where status = 'scheduled' and effective_date <= current_date
    order by effective_date, created_at
  loop
    if app.apply_employment_change(v_id) then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

-- Once a period is former, what was scheduled for it can never apply.
create or replace function app.cancel_changes_on_former() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'former' and old.status is distinct from 'former' then
    update public.employment_changes set status = 'cancelled'
      where employment_period_id = new.id and status = 'scheduled';
  end if;
  return new;
end $$;
create trigger cancel_changes_on_former after update of status on public.employment_periods
  for each row execute function app.cancel_changes_on_former();

create or replace function public.cancel_employment_change(p_change_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_change record;
begin
  select * into v_change from public.employment_changes where id = p_change_id for update;
  if not found then raise exception 'Change not found.'; end if;
  if not app.has_capability(v_change.company_id, 'employment.edit') then
    raise exception 'Cancelling a change requires employment.edit in this company.' using errcode = '42501';
  end if;
  if v_change.status <> 'scheduled' then
    raise exception 'Only a scheduled change can be cancelled.';
  end if;
  update public.employment_changes set status = 'cancelled' where id = p_change_id;
end $$;

revoke all on function public.schedule_employment_change(uuid, date, jsonb, text) from public, anon;
revoke all on function public.apply_due_employment_changes() from public, anon;
revoke all on function public.cancel_employment_change(uuid) from public, anon;
grant execute on function public.schedule_employment_change(uuid, date, jsonb, text) to authenticated, service_role;
grant execute on function public.apply_due_employment_changes() to authenticated, service_role;
grant execute on function public.cancel_employment_change(uuid) to authenticated, service_role;
