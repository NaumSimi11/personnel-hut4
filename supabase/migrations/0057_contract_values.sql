-- 0057_contract_values.sql
-- The facts a contract template fills itself from.
--
-- Gathered in one place so the preview HR reads and the PDF the person signs
-- cannot disagree. Everything comes from the record as it stands: if the salary
-- is missing here it is missing in the contract, and rendering says so rather
-- than printing a gap.
--
-- Note this deliberately reads the private row (national ID, address). It is
-- security definer, so the capability check is explicit: you need
-- personal.view in that company, the same gate the private card uses. Without
-- it you get the contract without those fields and rendering will tell you
-- which are missing, rather than silently issuing a contract with no ID number.

create or replace function public.contract_values(p_person_id uuid, p_employment_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_p record;
  v_e record;
  v_private record;
  v_may_see_private boolean;
begin
  select * into v_p from public.people where id = p_person_id;
  if not found then raise exception 'Person not found.'; end if;
  if not app.can_view_person(p_person_id) then
    raise exception 'You may not see this person.' using errcode = '42501';
  end if;

  select ep.*, c.name as company_name, c.legal_name as company_legal_name,
         d.name as department_name, m.full_name as manager_name, et.label as type_label
    into v_e
    from public.employment_periods ep
    left join public.companies c on c.id = ep.company_id
    left join public.departments d on d.id = ep.department_id
    left join public.people m on m.id = ep.manager_id
    left join public.employment_types et on et.key = ep.employment_type_key
    where ep.person_id = p_person_id
      and (p_employment_id is null or ep.id = p_employment_id)
    order by ep.start_date desc
    limit 1;

  v_may_see_private := v_e.company_id is not null and app.has_capability(v_e.company_id, 'personal.view');
  if v_may_see_private then
    select * into v_private from public.person_private_details where person_id = p_person_id;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'full_name', v_p.full_name,
    'work_email', v_p.work_email,
    'national_id', case when v_may_see_private then v_private.national_id end,
    'address', case when v_may_see_private then v_private.address end,
    'job_title', v_e.job_title,
    'department', v_e.department_name,
    'company', v_e.company_name,
    'company_legal_name', coalesce(v_e.company_legal_name, v_e.company_name),
    'start_date', to_char(v_e.start_date, 'YYYY-MM-DD'),
    'end_date', to_char(v_e.end_date, 'YYYY-MM-DD'),
    'employment_type', v_e.type_label,
    'manager', v_e.manager_name,
    'today', to_char(current_date, 'YYYY-MM-DD')
  ));
end $$;
grant execute on function public.contract_values(uuid, uuid) to authenticated;
