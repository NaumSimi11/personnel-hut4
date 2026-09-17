-- 0051_equipment_self_service_rpcs.sql
-- The four things a person and their HR do to hand equipment back, plus asking
-- for equipment in the first place. Every rule lives here rather than in the
-- page, because the page is not the only thing that will ever call them.

-- Who counts as HR in a company: whoever holds the capabilities HR work needs.
-- Not workflow_owners — that names exactly one person per company, and the
-- point of choosing is that the one named owner may be away.
create or replace function public.hr_people(p_company_id uuid)
returns table (id uuid, full_name text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.full_name
  from public.people p
  join public.access_grants g on g.person_id = p.id and g.company_id = p_company_id
  join public.grant_capabilities gc on gc.grant_id = g.id
  where gc.capability_key in ('people.view', 'tasks.assign')
  order by p.full_name
$$;
grant execute on function public.hr_people(uuid) to authenticated;

-- A person asking for equipment. it_requests is IT's queue already; this only
-- lets someone add to it about themselves, which RLS otherwise reserves for IT.
create or replace function public.request_equipment(
  p_company_id uuid, p_title text, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if coalesce(trim(p_title), '') = '' then
    raise exception 'Say what you need.';
  end if;
  -- You may only ask for yourself, and only where you actually work.
  if not exists (
    select 1 from public.employment_periods ep
    join public.employment_statuses es on es.key = ep.status
    where ep.person_id = v_me and ep.company_id = p_company_id and es.counts_as_employed
  ) then
    raise exception 'You have no current employment in that company.' using errcode = '42501';
  end if;

  insert into public.it_requests (company_id, person_id, kind, title, requested_by, requested_systems)
    values (p_company_id, v_me, 'manual', trim(p_title),
            v_me, case when coalesce(trim(p_note), '') = '' then '[]'::jsonb
                       else jsonb_build_array(jsonb_build_object('item', trim(p_note), 'issued_at', null, 'asset_id', null)) end)
    returning id into v_id;
  return jsonb_build_object('request_id', v_id);
end $$;
grant execute on function public.request_equipment(uuid, text, text) to authenticated;

-- Handing something back. The asset does not move yet: it stays with the person
-- until HR puts their name to the same document.
create or replace function public.start_equipment_return(
  p_asset_id uuid, p_hr_person_id uuid, p_reason text default null, p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_assignment public.asset_assignments;
  v_asset public.assets;
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
  if not exists (select 1 from public.hr_people(coalesce(v_asset.company_id, (
    select ep.company_id from public.employment_periods ep where ep.person_id = v_me limit 1))) h
    where h.id = p_hr_person_id) then
    raise exception 'That person does not handle HR for this company.';
  end if;

  insert into public.equipment_returns
      (asset_id, assignment_id, company_id, person_id, hr_person_id, reason, condition, signed_by_person_at)
    values (p_asset_id, v_assignment.id,
            coalesce(v_asset.company_id, (select ep.company_id from public.employment_periods ep where ep.person_id = v_me limit 1)),
            v_me, p_hr_person_id, nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  -- The form both sides put their name to.
  perform app.queue_generated_document('equipment_return', v_me, v_assignment.id, 'return:' || v_id);
  perform app.notify(p_hr_person_id, v_asset.company_id, 'equipment.return_requested',
    app.person_name(v_me) || ' is returning ' || v_asset.asset_tag,
    coalesce(v_asset.model, ''), '/me', 'equipment_return', v_id, 'equipment.return:' || v_id);
  return jsonb_build_object('return_id', v_id);
end $$;
grant execute on function public.start_equipment_return(uuid, uuid, text, text) to authenticated;

-- HR putting their name to it. Only now does the asset actually come back.
create or replace function public.accept_equipment_return(p_return_id uuid, p_condition text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  r public.equipment_returns;
begin
  select * into r from public.equipment_returns where id = p_return_id for update;
  if not found then
    raise exception 'Return not found.';
  end if;
  if r.status <> 'awaiting_hr' then
    raise exception 'This return is already %.', r.status;
  end if;
  if not (app.is_self(r.hr_person_id) or app.can_work_asset(r.company_id, 'it.assign')) then
    raise exception 'Only the named HR person may accept this return.' using errcode = '42501';
  end if;

  update public.asset_assignments
    set returned_at = now(), return_condition = coalesce(nullif(trim(coalesce(p_condition, '')), ''), r.condition)
    where id = r.assignment_id and returned_at is null;
  perform app.set_asset_status(r.asset_id, 'available');

  update public.equipment_returns
    set status = 'accepted', signed_by_hr_at = now(), signed_by_hr = v_me
    where id = p_return_id;

  perform app.notify(r.person_id, r.company_id, 'equipment.return_accepted',
    'Your equipment return was accepted', '', '/me', 'equipment_return', r.id,
    'equipment.return_accepted:' || r.id);
  return jsonb_build_object('status', 'accepted');
end $$;
grant execute on function public.accept_equipment_return(uuid, text) to authenticated;

create or replace function public.decline_equipment_return(p_return_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  r public.equipment_returns;
begin
  select * into r from public.equipment_returns where id = p_return_id for update;
  if not found then
    raise exception 'Return not found.';
  end if;
  if r.status <> 'awaiting_hr' then
    raise exception 'This return is already %.', r.status;
  end if;
  if not (app.is_self(r.hr_person_id) or app.can_work_asset(r.company_id, 'it.assign')) then
    raise exception 'Only the named HR person may decline this return.' using errcode = '42501';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Give the reason, so the person knows what to do next.';
  end if;

  -- The asset never moved, so declining only closes the request.
  update public.equipment_returns
    set status = 'declined', decline_reason = trim(p_reason), signed_by_hr = v_me, signed_by_hr_at = now()
    where id = p_return_id;

  perform app.notify(r.person_id, r.company_id, 'equipment.return_declined',
    'Your equipment return was not accepted', trim(p_reason), '/me', 'equipment_return', r.id,
    'equipment.return_declined:' || r.id);
  return jsonb_build_object('status', 'declined');
end $$;
grant execute on function public.decline_equipment_return(uuid, text) to authenticated;

-- Taking it back before HR has looked.
create or replace function public.cancel_equipment_return(p_return_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.equipment_returns;
begin
  select * into r from public.equipment_returns where id = p_return_id for update;
  if not found then raise exception 'Return not found.'; end if;
  if not app.is_self(r.person_id) then
    raise exception 'Only the person returning it may cancel.' using errcode = '42501';
  end if;
  if r.status <> 'awaiting_hr' then
    raise exception 'This return is already %.', r.status;
  end if;
  update public.equipment_returns set status = 'cancelled' where id = p_return_id;
  return jsonb_build_object('status', 'cancelled');
end $$;
grant execute on function public.cancel_equipment_return(uuid) to authenticated;
