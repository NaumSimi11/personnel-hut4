-- 0052_fix_return_document_queue.sql
-- The return form is not tied to a plan.
--
-- start_equipment_return passed the asset assignment's id as
-- queue_generated_document's p_plan_id, which is a foreign key to plans. A
-- self-service return has no plan behind it — that argument exists because the
-- only return form until now came from a scheduled departure. Passing null lets
-- the function fall back to the person's current employment for the company,
-- which is exactly right here.
--
-- Caught by running the flow rather than by reading it: the insert failed on
-- generated_documents_plan_id_fkey.

create or replace function public.start_equipment_return(
  p_asset_id uuid, p_hr_person_id uuid, p_reason text default null, p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_assignment public.asset_assignments;
  v_asset public.assets;
  v_company uuid;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_asset from public.assets where id = p_asset_id;
  if not found then
    raise exception 'Asset not found.';
  end if;
  select * into v_assignment from public.asset_assignments
    where asset_id = p_asset_id and person_id = v_me and returned_at is null
    order by issued_at desc nulls last limit 1;
  if not found then
    raise exception 'You do not hold this asset.' using errcode = '42501';
  end if;
  if exists (select 1 from public.equipment_returns where asset_id = p_asset_id and status = 'awaiting_hr') then
    raise exception 'A return of this asset is already waiting on HR.';
  end if;

  -- A pooled asset belongs to no company, so the return is filed against the
  -- company the person actually works for.
  v_company := coalesce(v_asset.company_id,
    (select ep.company_id from public.employment_periods ep
     join public.employment_statuses es on es.key = ep.status
     where ep.person_id = v_me and es.counts_as_employed
     order by ep.start_date desc limit 1));
  if v_company is null then
    raise exception 'You have no current employment to file this return against.';
  end if;

  if not exists (select 1 from public.hr_people(v_company) h where h.id = p_hr_person_id) then
    raise exception 'That person does not handle HR for this company.';
  end if;

  insert into public.equipment_returns
      (asset_id, assignment_id, company_id, person_id, hr_person_id, reason, condition, signed_by_person_at)
    values (p_asset_id, v_assignment.id, v_company, v_me, p_hr_person_id,
            nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  -- No plan: this return did not come from a departure.
  perform app.queue_generated_document('equipment_return', v_me, null, 'return:' || v_id);
  perform app.notify(p_hr_person_id, v_company, 'equipment.return_requested',
    app.person_name(v_me) || ' is returning ' || v_asset.asset_tag,
    coalesce(v_asset.model, ''), '/me', 'equipment_return', v_id, 'equipment.return:' || v_id);
  return jsonb_build_object('return_id', v_id);
end $$;
