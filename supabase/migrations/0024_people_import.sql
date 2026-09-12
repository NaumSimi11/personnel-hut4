-- 0024_people_import.sql
-- People import (plan 032): one function validates a whole file and, on
-- commit, writes it in one transaction — people, first employment, manager
-- links — or nothing at all. The preview is the same function without the
-- writes, so what the reader saw is exactly what gets written.

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
  v_status text;
  v_manager uuid;
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
    if length(v_title) < 2 then v_problems := array_append(v_problems, 'Job title is missing'); end if;
    begin
      v_start := (v_row->>'start_date')::date;
      if v_start is null then v_problems := array_append(v_problems, 'Start date is missing'); end if;
    exception when others then
      v_start := null;
      v_problems := array_append(v_problems, 'Start date is not a date (use YYYY-MM-DD)');
    end;
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
    v_status := case when v_start > current_date then 'pre_start' else 'active' end;
    insert into public.people (full_name, preferred_name, work_email, phone)
      values (trim(v_row->>'full_name'), nullif(trim(coalesce(v_row->>'preferred_name', '')), ''), v_email,
              nullif(trim(coalesce(v_row->>'phone', '')), ''))
      returning id into v_person;
    v_ids := v_ids || jsonb_build_object(v_email, v_person);
    insert into public.employment_periods
      (person_id, company_id, job_title, status, start_date, employment_type_key, department_id, location_id)
      values (v_person, p_company_id, trim(v_row->>'job_title'), v_status, v_start,
              nullif(trim(coalesce(v_row->>'employment_type_key', '')), ''),
              (v_verdicts->(v_i - 1)->>'department_id')::uuid,
              (v_verdicts->(v_i - 1)->>'location_id')::uuid);
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

revoke all on function public.import_people(uuid, jsonb, boolean) from public, anon;
grant execute on function public.import_people(uuid, jsonb, boolean) to authenticated, service_role;
