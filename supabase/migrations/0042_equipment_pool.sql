-- 0042_equipment_pool.sql
-- Plan 049: equipment for the holding, assigned to anyone, with signed forms.
--   1. The holding pool: assets.company_id null = the holding's; anyone with
--      the IT capabilities anywhere sees and works pool assets; a company
--      asset keeps its gate. Reserving needs a current employment anywhere.
--   2. The starter kit per company (companies.settings -> 'starter_kit', the
--      holding's list underneath): when an onboarding checklist starts, one
--      IT request of kind onboarding carries the kit as items; issuing every
--      item ticks the "Starter kit issued" line.
--   3. Generated documents: a queue the server drains — the equipment
--      handover form on issue, the return form when a departure is
--      scheduled (and, in 050, the welcome note). The signed scan comes back
--      as a new version; the "return form signed" line ticks on version 2.

-- ------------------------------------------------------------- 1. the pool
alter table public.assets alter column company_id drop not null;
alter table public.assets drop constraint assets_company_id_asset_tag_key;
alter table public.assets add constraint assets_company_id_asset_tag_key unique nulls not distinct (company_id, asset_tag);

-- May I read / work this asset? A pool asset answers to the capability
-- anywhere; a company asset to the capability there.
create or replace function app.can_see_asset(p_company_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_company_id is null then app.has_capability_anywhere('it.view')
              else app.has_capability(p_company_id, 'it.view') end
$$;
create or replace function app.can_work_asset(p_company_id uuid, p_cap text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_company_id is null then app.has_capability_anywhere(p_cap)
              else app.has_capability(p_company_id, p_cap) end
$$;
grant execute on function app.can_see_asset(uuid), app.can_work_asset(uuid, text) to authenticated;

drop policy sel on public.assets;
drop policy write on public.assets;
create policy sel on public.assets for select to authenticated using (app.can_see_asset(company_id));
create policy write on public.assets for all to authenticated
  using (app.can_work_asset(company_id, 'it.assign')) with check (app.can_work_asset(company_id, 'it.assign'));

drop policy sel on public.asset_assignments;
create policy sel on public.asset_assignments for select to authenticated
  using (app.is_self(person_id) or exists (
    select 1 from public.assets a where a.id = asset_id and app.can_see_asset(a.company_id)));

-- The location check on a pool asset: any live location.
create or replace function app.prepare_asset() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.asset_tag := upper(trim(coalesce(new.asset_tag, '')));
  if length(new.asset_tag) < 2 then
    raise exception 'Enter the asset tag.';
  end if;
  if tg_op = 'INSERT' then
    new.status := 'available';
  elsif auth.uid() is not null and current_setting('app.asset_transition', true) is distinct from 'on' then
    new.status := old.status;
    new.company_id := old.company_id;
  end if;
  if new.location_id is not null and (tg_op = 'INSERT' or new.location_id is distinct from old.location_id)
     and not exists (
       select 1 from public.locations l where l.id = new.location_id
         and (l.company_id is null or new.company_id is null or l.company_id = new.company_id) and l.archived_at is null) then
    raise exception 'That location belongs to another company or is archived.';
  end if;
  return new;
end $$;

create or replace function public.reserve_asset(p_asset_id uuid, p_person_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_asset record;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_asset from public.assets where id = p_asset_id for update;
  if not found then
    raise exception 'Asset not found.';
  end if;
  if not app.can_work_asset(v_asset.company_id, 'it.assign') then
    raise exception 'Reserving equipment needs it.assign in this company.' using errcode = '42501';
  end if;
  if v_asset.status <> 'available' then
    raise exception 'This asset is % — only an available asset can be reserved.', v_asset.status;
  end if;
  -- The holding's equipment goes to anyone currently employed anywhere; a
  -- company's asset stays with the company's people.
  if v_asset.company_id is null then
    if not exists (select 1 from public.employment_periods ep join public.employment_statuses es on es.key = ep.status
                   where ep.person_id = p_person_id and es.counts_as_employed) then
      raise exception 'This person has no current employment.';
    end if;
  elsif not exists (select 1 from public.employment_periods ep
                    where ep.person_id = p_person_id and ep.company_id = v_asset.company_id and ep.status <> 'former') then
    raise exception 'This person has no current employment in the asset''s company.';
  end if;
  insert into public.asset_assignments (asset_id, person_id, reserved_at, note)
    values (p_asset_id, p_person_id, now(), nullif(trim(coalesce(p_note, '')), ''))
    returning id into v_id;
  perform app.set_asset_status(p_asset_id, 'reserved');
  return jsonb_build_object('assignment_id', v_id);
end $$;

create or replace function public.issue_asset(p_assignment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_a record;
  v_company uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_a from public.asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'Assignment not found.';
  end if;
  select company_id into v_company from public.assets where id = v_a.asset_id;
  if not (app.can_work_asset(v_company, 'it.assign') or app.can_work_asset(v_company, 'it.complete')) then
    raise exception 'Issuing equipment needs it.assign or it.complete in this company.' using errcode = '42501';
  end if;
  if v_a.returned_at is not null or v_a.issued_at is not null then
    raise exception 'This assignment is not waiting to be issued.';
  end if;
  update public.asset_assignments set issued_at = now(), issued_by = v_me where id = p_assignment_id;
  perform app.set_asset_status(v_a.asset_id, 'assigned');
  -- The handover form, listing everything the person now holds.
  perform app.queue_generated_document('equipment_handover', v_a.person_id, null, 'issue:' || p_assignment_id);
  return jsonb_build_object('status', 'assigned');
end $$;

create or replace function public.return_asset(p_assignment_id uuid, p_condition text default null, p_status text default 'available') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_a record;
  v_company uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_status not in ('available', 'damaged', 'lost', 'retired') then
    raise exception 'After a return an asset is available, damaged, lost or retired.';
  end if;
  select * into v_a from public.asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'Assignment not found.';
  end if;
  select company_id into v_company from public.assets where id = v_a.asset_id;
  if not (app.can_work_asset(v_company, 'it.assign') or app.can_work_asset(v_company, 'it.complete')) then
    raise exception 'Returning equipment needs it.assign or it.complete in this company.' using errcode = '42501';
  end if;
  if v_a.returned_at is not null then
    raise exception 'This assignment is already closed.';
  end if;
  if v_a.issued_at is null then
    raise exception 'This asset was reserved but never issued; cancel the reservation instead.';
  end if;
  update public.asset_assignments
    set returned_at = now(), return_condition = nullif(trim(coalesce(p_condition, '')), '')
    where id = p_assignment_id;
  update public.assets set condition = coalesce(nullif(trim(coalesce(p_condition, '')), ''), condition) where id = v_a.asset_id;
  perform app.set_asset_status(v_a.asset_id, p_status);
  perform app.complete_equipment_task(v_a.asset_id, v_me);
  return jsonb_build_object('status', p_status);
end $$;

create or replace function public.cancel_reservation(p_assignment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_a record;
  v_company uuid;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_a from public.asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'Assignment not found.';
  end if;
  select company_id into v_company from public.assets where id = v_a.asset_id;
  if not app.can_work_asset(v_company, 'it.assign') then
    raise exception 'Cancelling a reservation needs it.assign in this company.' using errcode = '42501';
  end if;
  if v_a.returned_at is not null or v_a.issued_at is not null then
    raise exception 'Only an open reservation can be cancelled.';
  end if;
  delete from public.asset_assignments where id = p_assignment_id;
  perform app.set_asset_status(v_a.asset_id, 'available');
  -- A reservation cancelled during offboarding counts as taken back (0025).
  perform app.complete_equipment_task(v_a.asset_id, app.current_person_id());
  return jsonb_build_object('status', 'available');
end $$;

-- The leaver's return tasks cover everything they hold — the pool included.
create or replace function app.add_equipment_tasks(p_plan_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_plan record;
  v_n int;
begin
  select * into v_plan from public.plans where id = p_plan_id;
  if not found or v_plan.kind <> 'offboarding' then return 0; end if;
  insert into public.plan_tasks
      (plan_id, asset_id, title, description, owner_role, phase_key, due_date, critical, sort_order)
    select v_plan.id, a.id,
           format('Return %s · %s%s', a.asset_tag, t.label, coalesce(' ' || a.model, '')),
           'Equipment the person still holds; take it back and record its condition on the Equipment page.',
           'it', 'last_day', v_plan.start_date, true, 900 + row_number() over (order by a.asset_tag)
    from public.asset_assignments aa
    join public.assets a on a.id = aa.asset_id
    join public.asset_types t on t.key = a.type_key
    where aa.person_id = v_plan.person_id and aa.returned_at is null
      and not exists (select 1 from public.plan_tasks pt where pt.plan_id = v_plan.id and pt.asset_id = a.id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ------------------------------------------------------- 2. the starter kit
-- The company's list, else the holding's (companies.kind = 'holding').
-- The company's list, else the holding's, else the built-in list (a fresh
-- install, or a holding created after this migration).
create or replace function app.default_starter_kit() returns text[]
language sql immutable as $$
  select array['Laptop', 'Monitor', 'Keyboard & mouse', 'Badge / access card', 'Phone', 'Desk & chair', 'Software licences']
$$;
create or replace function app.starter_kit_for(p_company_id uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select array(select jsonb_array_elements_text(settings -> 'starter_kit')) from public.companies
      where id = p_company_id and jsonb_typeof(settings -> 'starter_kit') = 'array' and jsonb_array_length(settings -> 'starter_kit') > 0),
    (select array(select jsonb_array_elements_text(settings -> 'starter_kit')) from public.companies
      where kind = 'holding' and archived_at is null and jsonb_typeof(settings -> 'starter_kit') = 'array' and jsonb_array_length(settings -> 'starter_kit') > 0
      order by created_at limit 1),
    app.default_starter_kit())
$$;
grant execute on function app.starter_kit_for(uuid) to authenticated;
create or replace function public.starter_kit(p_company_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'items', to_jsonb(app.starter_kit_for(p_company_id)),
    'own', exists (select 1 from public.companies where id = p_company_id
                   and jsonb_typeof(settings -> 'starter_kit') = 'array' and jsonb_array_length(settings -> 'starter_kit') > 0))
$$;
grant execute on function public.starter_kit(uuid) to authenticated;

update public.companies set settings = settings || jsonb_build_object('starter_kit', to_jsonb(app.default_starter_kit()))
  where kind = 'holding' and archived_at is null and (settings -> 'starter_kit') is null;

/** The company's own kit; an empty list falls back to the holding's. it.assign here, or admin. */
create or replace function public.set_starter_kit(p_company_id uuid, p_items text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_items text[];
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not (app.is_admin() or app.has_capability(p_company_id, 'it.assign')) then
    raise exception 'Setting the starter kit needs it.assign in this company.' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct btrim(x) order by btrim(x)), '{}') into v_items
    from unnest(coalesce(p_items, '{}')) x where btrim(x) <> '';
  if cardinality(v_items) > 40 then
    raise exception 'A starter kit has at most 40 items.' using errcode = '22023';
  end if;
  update public.companies set settings = settings || jsonb_build_object('starter_kit', to_jsonb(v_items)) where id = p_company_id;
  return jsonb_build_object('items', to_jsonb(v_items));
end $$;
revoke all on function public.set_starter_kit(uuid, text[]) from public, anon;
grant execute on function public.set_starter_kit(uuid, text[]) to authenticated, service_role;

-- The kit request when a checklist starts: one IT request of kind
-- onboarding, its items on requested_systems, tied to the 'starter_kit' line.
create or replace function app.open_starter_kit(p_plan_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plan record;
  v_task uuid;
  v_items text[];
  v_id uuid;
begin
  select * into v_plan from public.plans where id = p_plan_id;
  if not found or v_plan.kind <> 'onboarding' then return null; end if;
  select id into v_task from public.plan_tasks where plan_id = p_plan_id and task_key = 'starter_kit';
  if v_task is null then return null; end if;
  if exists (select 1 from public.it_requests where plan_task_id = v_task) then
    return (select id from public.it_requests where plan_task_id = v_task limit 1);
  end if;
  v_items := app.starter_kit_for(v_plan.company_id);
  if cardinality(v_items) = 0 then return null; end if;
  perform set_config('app.it_transition', 'on', true);
  insert into public.it_requests (company_id, person_id, kind, title, requested_systems, due_at, plan_task_id, requested_by)
    values (v_plan.company_id, v_plan.person_id, 'onboarding', 'Starter kit',
            (select jsonb_agg(jsonb_build_object('item', x, 'issued_at', null, 'asset_id', null)) from unnest(v_items) x),
            (v_plan.start_date - 1)::timestamptz, v_task, app.current_person_id())
    returning id into v_id;
  perform set_config('app.it_transition', 'off', true);
  return v_id;
end $$;

-- Starting a checklist opens the kit request too.
create or replace function app.start_onboarding_plan(
  p_person_id uuid, p_company_id uuid, p_period_id uuid, p_start_date date
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_template_id uuid;
  v_plan_id uuid;
begin
  select id into v_plan_id from public.plans
    where employment_period_id = p_period_id and kind = 'onboarding'
    limit 1;
  if v_plan_id is not null then
    return v_plan_id;
  end if;
  v_template_id := app.template_for(p_company_id, 'onboarding');
  if v_template_id is null then
    return null;
  end if;
  insert into public.plans
      (kind, person_id, company_id, employment_period_id, template_id, hr_owner_id, start_date)
    values ('onboarding', p_person_id, p_company_id, p_period_id, v_template_id,
            app.current_person_id(), p_start_date)
    returning id into v_plan_id;
  perform app.copy_template_tasks(v_plan_id, v_template_id, p_start_date);
  perform app.tick_private_details(p_person_id);
  perform app.open_starter_kit(v_plan_id);
  return v_plan_id;
end $$;

/** One kit item issued; naming a registered asset reserves and issues it to the person in one go. */
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
    v_assignment := (public.reserve_asset(p_asset_id, v_r.person_id, 'Starter kit: ' || (v_item ->> 'item')) ->> 'assignment_id')::uuid;
    perform public.issue_asset(v_assignment);
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

/** The extra thing this hire needs. */
create or replace function public.add_kit_item(p_request_id uuid, p_item text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_r record; v_items jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_r from public.it_requests where id = p_request_id for update;
  if not found then
    raise exception 'Request not found.' using errcode = 'P0002';
  end if;
  if not (app.has_capability(v_r.company_id, 'it.assign') or app.has_capability(v_r.company_id, 'tasks.assign')) then
    raise exception 'Adding a kit item needs it.assign or tasks.assign in this company.' using errcode = '42501';
  end if;
  if v_r.status in ('done', 'cancelled') then
    raise exception 'This request is already %.', v_r.status using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_item, ''))) < 2 then
    raise exception 'Say what is needed.' using errcode = '22023';
  end if;
  v_items := v_r.requested_systems || jsonb_build_array(jsonb_build_object('item', btrim(p_item), 'issued_at', null, 'asset_id', null));
  perform set_config('app.it_transition', 'on', true);
  update public.it_requests set requested_systems = v_items where id = p_request_id;
  perform set_config('app.it_transition', 'off', true);
  return jsonb_build_object('items', v_items);
end $$;
revoke all on function public.issue_kit_item(uuid, int, uuid) from public, anon;
revoke all on function public.add_kit_item(uuid, text) from public, anon;
grant execute on function public.issue_kit_item(uuid, int, uuid) to authenticated, service_role;
grant execute on function public.add_kit_item(uuid, text) to authenticated, service_role;

-- The handover's starter_kit field reads the kit request.
create or replace function app.kit_summary(p_person_id uuid, p_period_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select string_agg((x ->> 'item') || case when (x ->> 'issued_at') is not null then ' ✓' else ' —' end, ', ')
  from public.it_requests r
  join public.plan_tasks pt on pt.id = r.plan_task_id
  join public.plans p on p.id = pt.plan_id
  cross join lateral jsonb_array_elements(r.requested_systems) x
  where r.person_id = p_person_id and r.kind = 'onboarding' and r.plan_task_id is not null
    and (p_period_id is null or p.employment_period_id = p_period_id)
$$;

-- ---------------------------------------------------- 3. generated documents
insert into public.document_categories (key, label, person_scoped, sort_order) values
  ('equipment_handover', 'Equipment handover form', true, 50),
  ('equipment_return', 'Equipment return form', true, 55),
  ('welcome_note', 'Welcome note', true, 60)
on conflict (key) do nothing;

-- The queue: the database says what to make; the server makes it.
create table public.generated_documents (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('equipment_handover', 'equipment_return', 'welcome_note')),
  person_id uuid not null references public.people(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  plan_id uuid references public.plans(id) on delete set null,
  requested_by uuid references public.people(id),
  status text not null default 'pending' check (status in ('pending', 'done', 'failed')),
  document_id uuid references public.documents(id) on delete set null,
  attempts int not null default 0,
  error text,
  dedupe_key text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index generated_documents_pending_idx on public.generated_documents (created_at) where status = 'pending';
create trigger touch before update on public.generated_documents for each row execute function app.touch_updated_at();
alter table public.generated_documents enable row level security;
create policy sel on public.generated_documents for select to authenticated
  using (app.has_capability(company_id, 'tasks.view') or app.has_capability(company_id, 'it.view'));
grant select on public.generated_documents to authenticated;
grant all on public.generated_documents to service_role;

/** Ask for a form. The company is the person's current employment (the plan's when given). */
create or replace function app.queue_generated_document(p_kind text, p_person_id uuid, p_plan_id uuid, p_occasion text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid; v_id uuid;
begin
  if p_plan_id is not null then
    select company_id into v_company from public.plans where id = p_plan_id;
  end if;
  if v_company is null then
    select ep.company_id into v_company from public.employment_periods ep
      join public.employment_statuses es on es.key = ep.status
      where ep.person_id = p_person_id and es.counts_as_employed
      order by ep.start_date desc limit 1;
  end if;
  if v_company is null then return null; end if;
  insert into public.generated_documents (kind, person_id, company_id, plan_id, requested_by, dedupe_key)
    values (p_kind, p_person_id, v_company, p_plan_id, app.current_person_id(), p_kind || ':' || p_person_id || ':' || p_occasion)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
  return v_id;
end $$;

-- The return form when a departure is scheduled: the plan insert is the moment.
create or replace function app.return_form_on_departure() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'offboarding' then
    perform app.queue_generated_document('equipment_return', new.person_id, new.id, 'plan:' || new.id);
  end if;
  return new;
end $$;
create trigger t9_return_form after insert on public.plans for each row execute function app.return_form_on_departure();

/** The server records the file it made, with the caller's identity as the uploader. */
create or replace function public.record_generated_document(
  p_queue_id uuid, p_storage_path text, p_size_bytes bigint, p_title text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  q public.generated_documents;
  v_doc uuid;
  v_visibility text;
begin
  select * into q from public.generated_documents where id = p_queue_id for update;
  if not found then
    raise exception 'Queue row not found.' using errcode = 'P0002';
  end if;
  -- A fresh form of the same kind archives the previous unsigned one, so
  -- every generated form is version 1 and only a person's upload (the
  -- signed scan) makes version 2 — which is what tick_return_form reads.
  update public.documents d set archived_at = now()
    where d.person_id = q.person_id and d.company_id = q.company_id and d.category_key = q.kind
      and d.archived_at is null and d.version = 1;
  v_visibility := 'person_and_hr';
  insert into public.documents
      (company_id, person_id, category_key, title, storage_path, visibility, original_name, mime_type, size_bytes, uploaded_by)
    values (q.company_id, q.person_id, q.kind, p_title, p_storage_path, v_visibility, p_title || '.pdf', 'application/pdf', p_size_bytes, q.requested_by)
    returning id into v_doc;
  update public.generated_documents set status = 'done', document_id = v_doc, error = null where id = p_queue_id;
  return jsonb_build_object('document_id', v_doc);
end $$;
revoke all on function public.record_generated_document(uuid, text, bigint, text) from public, anon, authenticated;
grant execute on function public.record_generated_document(uuid, text, bigint, text) to service_role;

-- prepare_document (0021's body) sets uploaded_by from the session; the
-- service role has none, so the queue's requester is kept when named.
create or replace function app.prepare_document() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_category record;
  v_old record;
begin
  -- The service role has no session: a generated document keeps the requester the queue named.
  new.uploaded_by := coalesce(app.current_person_id(), new.uploaded_by);
  new.archived_at := null;
  select * into v_category from public.document_categories where key = new.category_key;
  if not found or v_category.archived_at is not null then
    raise exception 'Choose the document category.';
  end if;
  if new.person_id is null and v_category.person_scoped then
    raise exception 'That category is for a person''s documents; choose a company category.';
  end if;
  if new.person_id is not null and not v_category.person_scoped then
    raise exception 'That category is for company documents; choose a person category.';
  end if;
  if new.person_id is not null and not exists (
       select 1 from public.employment_periods ep
       where ep.person_id = new.person_id and ep.company_id = new.company_id) then
    raise exception 'This person has no employment in that company.';
  end if;
  if length(trim(coalesce(new.title, ''))) < 2 then
    raise exception 'Enter the document title.';
  end if;
  new.title := trim(new.title);
  if new.person_id is not null and new.uploaded_by is not distinct from new.person_id
     and not app.has_capability(new.company_id, 'documents.upload') then
    new.visibility := 'person_and_hr';
  end if;

  if new.supersedes_id is not null then
    select * into v_old from public.documents where id = new.supersedes_id for update;
    if not found then
      raise exception 'The document this replaces was not found.';
    end if;
    if v_old.company_id <> new.company_id or v_old.person_id is distinct from new.person_id
       or v_old.category_key <> new.category_key then
      raise exception 'A new version must belong to the same person, company and category.';
    end if;
    if v_old.archived_at is not null then
      raise exception 'That document is archived; a live document is needed to add a version.';
    end if;
    new.version := v_old.version + 1;
    update public.documents set archived_at = now() where id = v_old.id;
  else
    new.version := 1;
  end if;
  return new;
end $$;

-- The signed scan (version 2+) of the return form ticks the line.
create or replace function app.tick_return_form() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_key = 'equipment_return' and new.version >= 2 and new.person_id is not null then
    update public.plan_tasks pt set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), pt.done_by)
      from public.plans p
     where pt.plan_id = p.id and pt.task_key = 'return_form' and pt.status in ('open', 'blocked')
       and p.person_id = new.person_id and p.company_id = new.company_id and p.kind = 'offboarding' and p.status = 'in_progress';
  end if;
  return new;
end $$;
create trigger tick_return_form after insert on public.documents for each row execute function app.tick_return_form();

-- What the forms print: the person, the company, and everything they hold.
create or replace function public.equipment_form_data(p_queue_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'kind', q.kind,
    'person', jsonb_build_object('name', p.full_name, 'position', ep.job_title, 'start_date', ep.start_date, 'last_working_date', ep.last_working_date),
    'company', jsonb_build_object('name', c.name, 'legal_name', c.legal_name),
    'assets', coalesce((select jsonb_agg(jsonb_build_object('tag', a.asset_tag, 'type', t.label, 'model', a.model, 'serial', a.serial_number, 'condition', a.condition, 'issued_at', aa.issued_at) order by a.asset_tag)
                        from public.asset_assignments aa join public.assets a on a.id = aa.asset_id join public.asset_types t on t.key = a.type_key
                        where aa.person_id = q.person_id and aa.returned_at is null and aa.issued_at is not null), '[]'::jsonb),
    'kit', coalesce((select r.requested_systems from public.it_requests r where r.person_id = q.person_id and r.kind = 'onboarding' and r.plan_task_id is not null order by r.created_at desc limit 1), '[]'::jsonb))
  from public.generated_documents q
  join public.people p on p.id = q.person_id
  join public.companies c on c.id = q.company_id
  left join lateral (select * from public.employment_periods e where e.person_id = q.person_id and e.company_id = q.company_id order by e.start_date desc limit 1) ep on true
  where q.id = p_queue_id
$$;
revoke all on function public.equipment_form_data(uuid) from public, anon, authenticated;
grant execute on function public.equipment_form_data(uuid) to service_role;

-- The handover's starter_kit value (0041 said 'None') now reads the kit.
create or replace function app.handover_value(p_key text, p_person_id uuid, p_period_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  ep public.employment_periods;
  pe public.people;
  pd public.person_private_details;
begin
  select * into ep from public.employment_periods where id = p_period_id;
  select * into pe from public.people where id = p_person_id;
  select * into pd from public.person_private_details where person_id = p_person_id;
  return case p_key
    when 'name' then pe.full_name
    when 'work_email' then pe.work_email::text
    when 'personal_email' then pe.personal_email::text
    when 'phone' then pe.phone
    when 'position' then ep.job_title
    when 'department' then (select name from public.departments where id = ep.department_id)
    when 'location' then (select name from public.locations where id = ep.location_id)
    when 'company' then (select name from public.companies where id = ep.company_id)
    when 'employment_type' then (select label from public.employment_types where key = ep.employment_type_key)
    when 'start_date' then to_char(ep.start_date, 'DD Mon YYYY')
    when 'end_date' then to_char(ep.end_date, 'DD Mon YYYY')
    when 'last_working_date' then to_char(ep.last_working_date, 'DD Mon YYYY')
    when 'manager' then (select full_name from public.people where id = ep.manager_id)
    when 'birth_date' then to_char(pd.birth_date, 'DD Mon YYYY')
    when 'address' then pd.address ->> 'line'
    when 'national_id' then pd.national_id
    when 'bank_account' then nullif(concat_ws(' · ', pd.bank_account ->> 'bank', pd.bank_account ->> 'account_number'), '')
    when 'salary' then (select amount::text || ' ' || currency || ' ' || pay_basis_key from public.compensation_records
                        where employment_period_id = p_period_id and status = 'approved'
                          and effective_date <= current_date and (end_date is null or end_date >= current_date)
                        order by effective_date desc limit 1)
    when 'starter_kit' then app.kit_summary(p_person_id, p_period_id)
    when 'equipment_held' then (select string_agg(a.asset_tag || coalesce(' ' || a.model, ''), ', ' order by a.asset_tag)
                                from public.asset_assignments aa join public.assets a on a.id = aa.asset_id
                                where aa.person_id = p_person_id and aa.returned_at is null and aa.issued_at is not null)
    else null
  end;
end $$;
