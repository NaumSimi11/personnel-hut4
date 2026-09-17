-- 0058_contract_values_fix.sql
-- Two corrections to contract_values, both found by calling it.
--
--   1. Referencing v_private.national_id when the viewer lacked personal.view
--      raised "record v_private is not assigned yet" — PL/pgSQL resolves the
--      record even inside a CASE that would not have used it. The private
--      fields are read into plain variables instead, assigned only when the
--      capability allows.
--
--   2. Salary and currency were missing altogether, though the template offers
--      them. They come from the approved compensation for the employment, and
--      only for a viewer holding salary.view — the same gate the compensation
--      card uses. Without it the contract renders without a salary and says so,
--      which is the right failure: a contract is not the place to discover that
--      somebody could not see the number.

create or replace function public.contract_values(p_person_id uuid, p_employment_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_p record;
  v_e record;
  v_national_id text;
  v_address text;
  v_amount numeric;
  v_currency text;
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

  if v_e.company_id is not null and app.has_capability(v_e.company_id, 'personal.view') then
    select pd.national_id, pd.address into v_national_id, v_address
      from public.person_private_details pd where pd.person_id = p_person_id;
  end if;

  if v_e.id is not null and app.has_capability(v_e.company_id, 'salary.view') then
    select cr.amount, cr.currency into v_amount, v_currency
      from public.compensation_records cr
      where cr.employment_period_id = v_e.id and cr.status = 'approved'
      order by cr.effective_date desc limit 1;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'full_name', v_p.full_name,
    'work_email', v_p.work_email,
    'national_id', v_national_id,
    'address', v_address,
    'job_title', v_e.job_title,
    'department', v_e.department_name,
    'company', v_e.company_name,
    'company_legal_name', coalesce(v_e.company_legal_name, v_e.company_name),
    'start_date', to_char(v_e.start_date, 'YYYY-MM-DD'),
    'end_date', to_char(v_e.end_date, 'YYYY-MM-DD'),
    'employment_type', v_e.type_label,
    'manager', v_e.manager_name,
    'salary', case when v_amount is not null then trim(to_char(v_amount, 'FM999999990.00')) end,
    'currency', v_currency,
    'today', to_char(current_date, 'YYYY-MM-DD')
  ));
end $$;
grant execute on function public.contract_values(uuid, uuid) to authenticated;
