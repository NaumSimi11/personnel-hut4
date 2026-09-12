-- 0026_company_structure.sql
-- Company structure (plan 035a): the holding employs people (the pickers
-- were the only thing saying otherwise), a transfer moves a person between
-- companies as one act (end here the day before, start there on the date),
-- and a company with people still employed cannot be archived.

alter table public.employment_periods
  add column transferred_to_period_id uuid references public.employment_periods(id);
create index employment_periods_transfer_idx on public.employment_periods (transferred_to_period_id)
  where transferred_to_period_id is not null;

-- --------------------------------------------------------------- transfer
create or replace function public.transfer_employment(
  p_period_id uuid,
  p_company_id uuid,
  p_effective_date date,
  p_job_title text default null,
  p_employment_type_key text default null,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period public.employment_periods;
  v_target record;
  v_new uuid;
  v_title text;
  v_type text;
  v_now boolean;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'Employment period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'employment.edit') then
    raise exception 'Transferring needs employment.edit in the current company.' using errcode = '42501';
  end if;
  select * into v_target from public.companies where id = p_company_id;
  if not found or v_target.archived_at is not null then
    raise exception 'The target company is not available.';
  end if;
  if not app.has_capability(p_company_id, 'employment.edit') then
    raise exception 'Transferring needs employment.edit in the target company.' using errcode = '42501';
  end if;
  if p_company_id = v_period.company_id then
    raise exception 'That is the company the person already works for; schedule a change instead.';
  end if;
  if v_period.status = 'former' then
    raise exception 'This employment has ended; add a new period instead.';
  end if;
  if v_period.transferred_to_period_id is not null then
    raise exception 'A transfer is already scheduled for this employment.';
  end if;
  if p_effective_date is null then
    raise exception 'Choose the transfer date.';
  end if;
  if p_effective_date <= v_period.start_date then
    raise exception 'The transfer date must be after the employment started (%).', v_period.start_date;
  end if;
  -- A scheduled departure has its own plan, dates and reason; a transfer must
  -- not silently overwrite them.
  if v_period.end_date is not null then
    raise exception 'A departure is already scheduled for this employment (ending %); it cannot also be transferred.', v_period.end_date;
  end if;
  v_now := p_effective_date <= current_date;

  -- Changes due before the move still belong to the old employment: apply
  -- them first, so closing it cancels only what was dated on or after, and
  -- the new period carries what the old one had become.
  perform app.apply_employment_change(c.id)
    from public.employment_changes c
    where c.employment_period_id = p_period_id and c.status = 'scheduled' and c.effective_date < p_effective_date;
  select * into v_period from public.employment_periods where id = p_period_id;
  v_title := coalesce(nullif(trim(coalesce(p_job_title, '')), ''), v_period.job_title);
  v_type := coalesce(nullif(trim(coalesce(p_employment_type_key, '')), ''), v_period.employment_type_key);
  if v_type is not null and not exists (select 1 from public.employment_types where key = v_type and archived_at is null) then
    raise exception 'Employment type not found.';
  end if;

  -- The old period closes the day before: dates first (so the exclusion
  -- constraint accepts the new range), status when the day has come.
  update public.employment_periods
    set end_date = p_effective_date - 1, last_working_date = p_effective_date - 1
    where id = p_period_id;
  insert into public.employment_periods
      (person_id, company_id, job_title, employment_type_key, status, start_date)
    values (v_period.person_id, p_company_id, v_title, v_type,
            case when v_now then 'active' else 'pre_start' end, p_effective_date)
    returning id into v_new;
  update public.employment_periods set transferred_to_period_id = v_new where id = p_period_id;
  if v_now then
    update public.employment_periods set status = 'former' where id = p_period_id;
  end if;
  -- What was scheduled for the old period cannot apply after the move.
  update public.employment_changes
    set status = 'cancelled', reason = concat_ws(' — ', reason, 'Cancelled by transfer')
    where employment_period_id = p_period_id and status = 'scheduled' and effective_date >= p_effective_date;
  if nullif(trim(coalesce(p_reason, '')), '') is not null then
    insert into public.employment_changes
        (employment_period_id, company_id, effective_date, changes, reason, created_by, status, applied_at)
      values (v_new, p_company_id, p_effective_date,
              jsonb_build_object('transfer_from', v_period.company_id), trim(p_reason), v_me, 'applied', now());
  end if;
  return jsonb_build_object('new_period_id', v_new, 'applied', v_now);
end $$;

revoke all on function public.transfer_employment(uuid, uuid, date, text, text, text) from public, anon;
grant execute on function public.transfer_employment(uuid, uuid, date, text, text, text) to authenticated, service_role;

-- Due transfers complete with the other due changes (nightly via pg_cron,
-- or on the way in for editors): the old period becomes former on the day.
create or replace function public.apply_due_employment_changes() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_n int := 0;
begin
  for v_id in
    select c.id from public.employment_changes c
    where c.status = 'scheduled' and c.effective_date <= current_date
      and (auth.uid() is null or app.has_capability(c.company_id, 'employment.edit'))
    order by c.effective_date, c.created_at
  loop
    if app.apply_employment_change(v_id) then v_n := v_n + 1; end if;
  end loop;
  update public.employment_periods old
    set status = 'former'
    from public.employment_periods nxt
    where old.transferred_to_period_id = nxt.id and old.status <> 'former'
      and nxt.start_date <= current_date
      and (auth.uid() is null or app.has_capability(old.company_id, 'employment.edit'));
  update public.employment_periods nxt
    set status = 'active'
    from public.employment_periods old
    where old.transferred_to_period_id = nxt.id and nxt.status = 'pre_start'
      and nxt.start_date <= current_date
      and (auth.uid() is null or app.has_capability(nxt.company_id, 'employment.edit'));
  return v_n;
end $$;

-- ------------------------------------------------------- closing a company
create or replace function app.employed_count(p_company_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(distinct ep.person_id)::int from public.employment_periods ep
  where ep.company_id = p_company_id and ep.status <> 'former'
$$;
grant execute on function app.employed_count(uuid) to authenticated;

create or replace function public.archive_company(p_company_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_company record;
  v_employed int;
begin
  if not app.is_admin() then
    raise exception 'Archiving a company needs platform admin access.' using errcode = '42501';
  end if;
  select * into v_company from public.companies where id = p_company_id for update;
  if not found then
    raise exception 'Company not found.';
  end if;
  if v_company.kind = 'holding' then
    raise exception 'The holding cannot be archived.';
  end if;
  if v_company.archived_at is not null then
    return jsonb_build_object('archived', true, 'already', true);
  end if;
  v_employed := app.employed_count(p_company_id);
  if v_employed > 0 then
    raise exception '% % still employed here — transfer them or end their employment first.',
      v_employed, case when v_employed = 1 then 'person is' else 'people are' end;
  end if;
  update public.companies set archived_at = now() where id = p_company_id;
  return jsonb_build_object('archived', true, 'already', false);
end $$;
revoke all on function public.archive_company(uuid) from public, anon;
grant execute on function public.archive_company(uuid) to authenticated, service_role;

-- The same rule on the direct update, so nothing can slip past the function.
create or replace function app.guard_company_archive() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.archived_at is not null and old.archived_at is null then
    if new.kind = 'holding' then
      raise exception 'The holding cannot be archived.';
    end if;
    if app.employed_count(new.id) > 0 then
      raise exception '% still employed here — transfer them or end their employment first.',
        app.employed_count(new.id) || case when app.employed_count(new.id) = 1 then ' person is' else ' people are' end;
    end if;
  end if;
  return new;
end $$;
create trigger guard_company_archive before update on public.companies
  for each row execute function app.guard_company_archive();
