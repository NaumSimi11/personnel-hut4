-- 0094_kit_says_what_went_out.sql
-- The starter kit says what went out, and tells who hands it over (plan 074).
--
--   1. Two equipment types the kit lines name and the register lacked:
--      Badge ("Badge / access card") and Furniture ("Desk & chair").
--   2. A kit line issued with a registered asset keeps what it was — tag,
--      model, type, owner — in the line itself, so the checklist can name it
--      after the asset has left the free list (the only list the page reads).
--   3. Somebody has to get that laptop off a shelf (HR, 2026-10-09: "who needs
--      to know WHAT laptop, needs to pick it up?"). Issuing a registered asset
--      through the kit now tells:
--        * the IT owner of the company that owns the asset — they keep that
--          stock — or, when that company has none, the hire's company's IT
--          owner; the company's IT inbox gets the mail when one is set;
--        * the hire, so they know what is theirs.
--      Nobody is told what they just did themselves.

begin;

-- ------------------------------------------------------------------ types
insert into public.asset_types (key, label, is_physical) values
  ('badge', 'Badge', true),
  ('furniture', 'Furniture', true)
on conflict (key) do nothing;

-- -------------------------------------------------------------- IT owner
create or replace function app.it_owner_of(p_company_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select w.person_id from public.workflow_owners w join public.people p on p.id = w.person_id
   where w.company_id = p_company_id and w.role_key = 'it_owner' and p.archived_at is null
$$;

-- ------------------------------------------------------- tell who hands it
create or replace function app.notify_kit_issue(p_request_id uuid, p_asset_id uuid, p_assignment_id uuid, p_me uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_r record;
  v_a record;
  v_plan record;
  v_holder uuid;
  v_holder_company uuid;
  v_inbox text;
  v_what text;
  v_where text;
  v_link text;
begin
  select r.id, r.company_id, r.person_id, r.plan_task_id, co.name as company_name, app.person_name(r.person_id) as hire
    into v_r
    from public.it_requests r join public.companies co on co.id = r.company_id
   where r.id = p_request_id;
  select a.asset_tag, a.model, a.serial_number, a.company_id, t.label as type_label,
         coalesce(co.name, 'the shared pool') as owner_name, l.name as location
    into v_a
    from public.assets a
    left join public.asset_types t on t.key = a.type_key
    left join public.companies co on co.id = a.company_id
    left join public.locations l on l.id = a.location_id
   where a.id = p_asset_id;
  select p.id, p.start_date into v_plan
    from public.plan_tasks pt join public.plans p on p.id = pt.plan_id
   where pt.id = v_r.plan_task_id;

  v_what := concat_ws(' · ', v_a.asset_tag, v_a.model, v_a.type_label,
                      case when v_a.serial_number is not null then 'serial ' || v_a.serial_number end);
  v_where := v_a.owner_name || '''s' || coalesce(', kept at ' || v_a.location, ', no location recorded');
  v_link := case when v_plan.id is not null then '/onboarding/' || v_plan.id else '/people/' || v_r.person_id end;

  -- Whoever keeps the stock, else whoever looks after the hire's company.
  v_holder := case when v_a.company_id is not null then app.it_owner_of(v_a.company_id) end;
  v_holder_company := v_a.company_id;
  if v_holder is null then
    v_holder := app.it_owner_of(v_r.company_id);
    v_holder_company := v_r.company_id;
  end if;
  if v_holder is not null and v_holder is distinct from p_me then
    perform app.notify(v_holder, v_holder_company, 'equipment.kit_issued',
      'Hand over ' || v_a.asset_tag || ' to ' || v_r.hire,
      v_what || ' (' || v_where || ') · starter kit for ' || v_r.hire || ', ' || v_r.company_name
        || coalesce(', starts ' || to_char(v_plan.start_date, 'DD Mon YYYY'), ''),
      v_link, 'asset_assignment', p_assignment_id, 'equipment.kit_issued:' || p_assignment_id);
    v_inbox := (select nullif(btrim(it_notification_email), '') from public.companies where id = v_holder_company);
    if v_inbox is not null then
      update public.notifications set email_to = v_inbox, email_status = 'pending'
       where dedupe_key = 'equipment.kit_issued:' || p_assignment_id || ':' || v_holder;
    end if;
  end if;

  if v_r.person_id is distinct from p_me then
    perform app.notify(v_r.person_id, v_r.company_id, 'equipment.kit_yours',
      'Your starter kit: ' || concat_ws(' · ', v_a.asset_tag, v_a.model),
      v_what || coalesce(' · kept at ' || v_a.location, '')
        || coalesce(' · ' || app.person_name(v_holder) || ' hands it over', ''),
      '/me', 'asset_assignment', p_assignment_id, 'equipment.kit_yours:' || p_assignment_id);
  end if;
end $$;

-- ---------------------------------------------------------- the kit door
-- 0092's function, now keeping what was issued on the line and telling who
-- hands it over.
create or replace function public.issue_kit_item(p_request_id uuid, p_index int, p_asset_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
  v_items jsonb;
  v_item jsonb;
  v_assignment uuid;
  v_asset jsonb;
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
    select jsonb_build_object('asset_tag', a.asset_tag, 'model', a.model, 'type_label', t.label,
                              'company_name', coalesce(co.name, 'Shared pool'))
      into v_asset
      from public.assets a
      left join public.asset_types t on t.key = a.type_key
      left join public.companies co on co.id = a.company_id
     where a.id = p_asset_id;
  end if;
  v_items := jsonb_set(v_items, array[p_index::text],
    v_item || jsonb_build_object('issued_at', now(), 'asset_id', p_asset_id, 'issued_by', v_me)
           || case when v_asset is not null then jsonb_build_object('asset', v_asset) else '{}'::jsonb end);
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
  if p_asset_id is not null then
    perform app.notify_kit_issue(p_request_id, p_asset_id, v_assignment, v_me);
  end if;
  return jsonb_build_object('items', v_items, 'done', v_all);
end $$;

revoke all on function app.it_owner_of(uuid), app.notify_kit_issue(uuid, uuid, uuid, uuid) from public;

commit;
