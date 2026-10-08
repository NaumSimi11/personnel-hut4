-- 0092_free_equipment_for_anyone.sql
-- Free equipment goes to anyone in the holding (plan 072). The onboarding
-- starter kit offered a hire only their own company's free assets and the
-- holding pool — and Snowball owns none, the pool was empty, so a Snowball
-- hire saw an empty list while 120 assets sat free at Synami, Hut4 and
-- Liquiditas. The maintainer's rule (2026-10-08): "When the equipment has a
-- relation with a particular employee, we can't give it to anyone. No other
-- rules exist." So an asset that is available — reserved and assigned are
-- the relation — may go to anyone currently employed anywhere in the
-- holding. It stays on its owner's books; only who holds it changes.
--
-- Who may do the handing over is unchanged: reserve_asset and issue_asset
-- still want it.assign (or it.complete) where the asset is. The starter
-- kit's own door, issue_kit_item, already asks for it in the hire's company,
-- and from now on that is enough — the kit is how the hire's HR gives out
-- the holding's stock. kit_asset_options lists that stock for the kit, past
-- the reader's own asset visibility.

begin;

-- ----------------------------------------------------- the two core steps
-- The rules of reserving and issuing, without the question of who is
-- asking: the public doors ask it first, the kit asks it of its own company.
create or replace function app.reserve_asset_for(p_asset_id uuid, p_person_id uuid, p_note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_asset record; v_id uuid;
begin
  select * into v_asset from public.assets where id = p_asset_id for update;
  if not found then
    raise exception 'Asset not found.';
  end if;
  if v_asset.status <> 'available' then
    raise exception 'This asset is % — only an available asset can be reserved.', v_asset.status;
  end if;
  if not exists (select 1 from public.employment_periods ep join public.employment_statuses es on es.key = ep.status
                  where ep.person_id = p_person_id and es.counts_as_employed) then
    raise exception 'This person has no current employment.';
  end if;
  insert into public.asset_assignments (asset_id, person_id, reserved_at, note)
    values (p_asset_id, p_person_id, now(), nullif(trim(coalesce(p_note, '')), ''))
    returning id into v_id;
  perform app.set_asset_status(p_asset_id, 'reserved');
  return v_id;
end $$;

create or replace function app.issue_asset_for(p_assignment_id uuid, p_me uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_a record;
begin
  select * into v_a from public.asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'Assignment not found.';
  end if;
  if v_a.returned_at is not null or v_a.issued_at is not null then
    raise exception 'This assignment is not waiting to be issued.';
  end if;
  update public.asset_assignments set issued_at = now(), issued_by = p_me where id = p_assignment_id;
  perform app.set_asset_status(v_a.asset_id, 'assigned');
  -- The handover form, listing everything the person now holds.
  perform app.queue_generated_document('equipment_handover', v_a.person_id, null, 'issue:' || p_assignment_id);
end $$;

-- ------------------------------------------------------- the public doors
create or replace function public.reserve_asset(p_asset_id uuid, p_person_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_company uuid;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select company_id into v_company from public.assets where id = p_asset_id;
  if not found then
    raise exception 'Asset not found.';
  end if;
  if not app.can_work_asset(v_company, 'it.assign') then
    raise exception 'Reserving equipment needs it.assign in this company.' using errcode = '42501';
  end if;
  return jsonb_build_object('assignment_id', app.reserve_asset_for(p_asset_id, p_person_id, p_note));
end $$;

create or replace function public.issue_asset(p_assignment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me uuid := app.current_person_id(); v_company uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select a.company_id into v_company
    from public.asset_assignments x join public.assets a on a.id = x.asset_id
   where x.id = p_assignment_id;
  if not found then
    raise exception 'Assignment not found.';
  end if;
  if not (app.can_work_asset(v_company, 'it.assign') or app.can_work_asset(v_company, 'it.complete')) then
    raise exception 'Issuing equipment needs it.assign or it.complete in this company.' using errcode = '42501';
  end if;
  perform app.issue_asset_for(p_assignment_id, v_me);
  return jsonb_build_object('status', 'assigned');
end $$;

-- ---------------------------------------------------------- the kit door
-- 0042's function with its two calls swapped for the core steps: the kit's
-- capability check, in the hire's company, is the one that counts.
create or replace function public.issue_kit_item(p_request_id uuid, p_index int, p_asset_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
  v_items jsonb;
  v_item jsonb;
  v_assignment uuid;
  v_all boolean;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_r from public.it_requests where id = p_request_id for update;
  if not found then
    raise exception 'Request not found.' using errcode = 'P0002';
  end if;
  if not (app.has_capability(v_r.company_id, 'it.assign') or app.has_capability(v_r.company_id, 'it.complete')) then
    raise exception 'Issuing the kit needs it.assign or it.complete in this company.' using errcode = '42501';
  end if;
  if v_r.status in ('done', 'cancelled') then
    raise exception 'This request is already %.', v_r.status using errcode = '22023';
  end if;
  v_items := v_r.requested_systems;
  if p_index < 0 or p_index >= jsonb_array_length(v_items) then
    raise exception 'No such item.' using errcode = '22023';
  end if;
  v_item := v_items -> p_index;
  if (v_item ->> 'issued_at') is not null then
    raise exception 'That item is already issued.' using errcode = '22023';
  end if;
  if p_asset_id is not null then
    v_assignment := app.reserve_asset_for(p_asset_id, v_r.person_id, 'Starter kit: ' || (v_item ->> 'item'));
    perform app.issue_asset_for(v_assignment, v_me);
  end if;
  v_items := jsonb_set(v_items, array[p_index::text], v_item || jsonb_build_object('issued_at', now(), 'asset_id', p_asset_id, 'issued_by', v_me));
  select bool_and((x ->> 'issued_at') is not null) into v_all from jsonb_array_elements(v_items) x;
  perform set_config('app.it_transition', 'on', true);
  update public.it_requests
     set requested_systems = v_items,
         status = case when v_all then 'done' else case when status = 'open' then 'in_progress' else status end end,
         assignee_id = coalesce(assignee_id, v_me)
   where id = p_request_id;
  perform set_config('app.it_transition', 'off', true);
  if v_all and v_r.plan_task_id is not null then
    update public.plan_tasks set status = 'done', done_at = now(), done_by = v_me
      where id = v_r.plan_task_id and status in ('open', 'blocked');
  end if;
  return jsonb_build_object('items', v_items, 'done', v_all);
end $$;

-- ---------------------------------------------------- what the kit offers
-- Every available asset in the holding, whoever owns it, for whoever may
-- issue this kit — the same check issue_kit_item makes.
create or replace function public.kit_asset_options(p_request_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_company uuid;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select company_id into v_company from public.it_requests where id = p_request_id;
  if not found then
    raise exception 'Request not found.' using errcode = 'P0002';
  end if;
  if not (app.has_capability(v_company, 'it.assign') or app.has_capability(v_company, 'it.complete')) then
    raise exception 'Issuing the kit needs it.assign or it.complete in this company.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'asset_tag', a.asset_tag, 'model', a.model, 'serial_number', a.serial_number,
             'type_key', a.type_key, 'type_label', t.label,
             'company_id', a.company_id, 'company_name', co.name)
           order by t.label nulls last, a.asset_tag)
      from public.assets a
      left join public.asset_types t on t.key = a.type_key
      left join public.companies co on co.id = a.company_id
     where a.status = 'available'), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function app.reserve_asset_for(uuid, uuid, text), app.issue_asset_for(uuid, uuid) from public;
revoke all on function public.kit_asset_options(uuid) from public, anon;
grant execute on function public.kit_asset_options(uuid) to authenticated;

commit;
