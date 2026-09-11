-- 0018_hardening.sql
-- Review findings across 0014–0017 (plan 025):
--   1. The audit trail copied blind scorecards, compensation amounts and offer
--      terms into activity_log, which access.manage / candidates.view holders
--      can read. Those tables now audit through app.audit_redacted(), which
--      keeps the row identity and actors but strips the named fields; the
--      existing rows are redacted in place.
--   2. app.would_create_cycle walked each person's latest period regardless
--      of company, so a loop inside one company was missed when someone had
--      a later period elsewhere. It now walks within the company.
--   3. Deferred employment changes re-ran only the former/cycle guards; the
--      department / location / type / manager checks now live in one
--      validator used at scheduling and at apply time.
--   4. One open application per candidate per job is enforced by the
--      database, not only by the careers service's read-then-insert.

-- ------------------------------------------------------- 1. redacted audit
create or replace function app.audit_redacted() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb := to_jsonb(coalesce(new, old));
  v_keys text[] := string_to_array(coalesce(tg_argv[0], ''), ',');
  v_before jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) - v_keys end;
  v_after jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) - v_keys end;
begin
  insert into public.activity_log
    (company_id, actor_person_id, actor_user_id, entity_type, entity_id, action, before, after)
  values (
    (rec->>'company_id')::uuid,
    app.current_person_id(),
    auth.uid(),
    tg_table_name,
    rec->>'id',
    tg_op,
    v_before,
    v_after
  );
  return coalesce(new, old);
end $$;

drop trigger if exists audit on public.scorecards;
create trigger audit after insert or update or delete on public.scorecards
  for each row execute function app.audit_redacted('ratings,recommendation,summary');

drop trigger if exists audit on public.compensation_records;
create trigger audit after insert or update or delete on public.compensation_records
  for each row execute function app.audit_redacted('amount,note');

drop trigger if exists audit on public.offers;
create trigger audit after insert or update or delete on public.offers
  for each row execute function app.audit_redacted('terms');

-- compensation_records carries no company_id, so its log rows have none and
-- were never readable through the company policies — redact them anyway.
update public.activity_log
  set before = before - array['ratings', 'recommendation', 'summary'],
      after = after - array['ratings', 'recommendation', 'summary']
  where entity_type = 'scorecards';
update public.activity_log
  set before = before - array['amount', 'note'], after = after - array['amount', 'note']
  where entity_type = 'compensation_records';
update public.activity_log
  set before = before - 'terms', after = after - 'terms'
  where entity_type = 'offers';

-- ------------------------------------------- 2. cycle check within a company
drop function if exists app.would_create_cycle(uuid, uuid);
create or replace function app.would_create_cycle(person uuid, manager uuid, company uuid) returns boolean
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
      where ep.person_id = v_cursor and ep.company_id = company and ep.status <> 'former'
      order by ep.start_date desc
      limit 1;
    if v_cursor = person then return true; end if;
    v_hops := v_hops + 1;
  end loop;
  return false;
end $$;

-- ------------------------------------ 3. one validator, scheduling and apply
-- Raises with the user-facing reason; callers decide whether that becomes an
-- error (scheduling) or a failed change (apply).
create or replace function app.validate_employment_change(p_period public.employment_periods, p_changes jsonb)
returns void
language plpgsql stable security definer set search_path = public as $$
declare
  v_dept_company uuid;
  v_loc_company uuid;
  v_manager uuid;
  v_key text;
begin
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
    if v_dept_company is not null and v_dept_company <> p_period.company_id then
      raise exception 'That department belongs to another company.';
    end if;
  end if;
  if nullif(p_changes->>'location_id', '') is not null then
    select company_id into v_loc_company from public.locations
      where id = (p_changes->>'location_id')::uuid and archived_at is null;
    if not found then raise exception 'Location not found.'; end if;
    if v_loc_company is not null and v_loc_company <> p_period.company_id then
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
    if v_manager = p_period.person_id then
      raise exception 'A person cannot be their own manager.';
    end if;
    if app.would_create_cycle(p_period.person_id, v_manager, p_period.company_id) then
      raise exception 'That would create a circular reporting line: the proposed manager already reports to this person.';
    end if;
  end if;
end $$;

create or replace function app.apply_employment_change(change_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_change record;
  v_period public.employment_periods;
begin
  select * into v_change from public.employment_changes where id = change_id for update;
  if not found or v_change.status <> 'scheduled' then return false; end if;
  select * into v_period from public.employment_periods where id = v_change.employment_period_id for update;
  if not found or v_period.status = 'former' then
    update public.employment_changes set status = 'failed', failure_reason = 'The employment ended before the change applied.'
      where id = change_id;
    return false;
  end if;
  -- The world may have moved since scheduling: every guard runs again.
  begin
    perform app.validate_employment_change(v_period, v_change.changes);
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

create or replace function public.schedule_employment_change(
  p_period_id uuid,
  p_effective_date date,
  p_changes jsonb,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period public.employment_periods;
  v_change_id uuid;
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
  perform app.validate_employment_change(v_period, p_changes);

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

-- --------------------------------- 4. one open application per candidate/job
-- Duplicates the race may already have produced: keep the oldest open one,
-- withdraw the rest with a note so nothing is deleted and the index can build.
with ranked as (
  select id, row_number() over (partition by job_id, candidate_id order by created_at, id) as n
  from public.applications
  where stage_key not in ('hired', 'rejected', 'withdrawn')
),
withdrawn as (
  update public.applications a
    set stage_key = 'withdrawn'
    from ranked r
    where a.id = r.id and r.n > 1
    returning a.id
)
insert into public.application_events (application_id, kind, body)
  select id, 'note', 'Withdrawn automatically: a duplicate of an earlier open application for the same role.'
  from withdrawn;
create unique index applications_one_open_per_candidate
  on public.applications (job_id, candidate_id)
  where stage_key not in ('hired', 'rejected', 'withdrawn');
