-- 0022_equipment.sql
-- Equipment & IT (plan 029): the asset register keeps its RLS (0006), but an
-- asset's status is derived from its assignments, which move only through
-- the functions below; IT requests are pinned on insert and advanced through
-- advance_it_request.

-- ------------------------------------------------------------------ assets
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
    new.status := old.status;   -- the register edits facts, never the status
    new.company_id := old.company_id;
  end if;
  -- Checked when set or changed: an archived location must not block a
  -- return or a status change on an asset that already sits there.
  if new.location_id is not null and (tg_op = 'INSERT' or new.location_id is distinct from old.location_id)
     and not exists (
       select 1 from public.locations l where l.id = new.location_id
         and (l.company_id is null or l.company_id = new.company_id) and l.archived_at is null) then
    raise exception 'That location belongs to another company or is archived.';
  end if;
  return new;
end $$;
create trigger prepare_asset before insert or update on public.assets
  for each row execute function app.prepare_asset();

-- One open assignment per asset: one_open_assignment_per_asset (0004).

-- Assignments are written by the functions only: the 0006 write policy goes.
drop policy if exists write on public.asset_assignments;

-- A person sees the assets they hold or that are reserved for them, whatever
-- their IT capabilities. The helper reads assignments directly so the two
-- tables' policies never recurse into each other.
create or replace function app.holds_asset(asset uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.asset_assignments a
                 where a.asset_id = asset and a.person_id = app.current_person_id() and a.returned_at is null)
$$;
grant execute on function app.holds_asset(uuid) to authenticated;
create policy sel_holder on public.assets for select to authenticated
  using (app.holds_asset(id));

create or replace function app.set_asset_status(p_asset_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.asset_transition', 'on', true);
  update public.assets set status = p_status where id = p_asset_id;
  perform set_config('app.asset_transition', 'off', true);
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
  if not app.has_capability(v_asset.company_id, 'it.assign') then
    raise exception 'Reserving equipment needs it.assign in this company.' using errcode = '42501';
  end if;
  if v_asset.status <> 'available' then
    raise exception 'This asset is % — only an available asset can be reserved.', v_asset.status;
  end if;
  if not exists (select 1 from public.employment_periods ep
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
  if not (app.has_capability(v_company, 'it.assign') or app.has_capability(v_company, 'it.complete')) then
    raise exception 'Issuing equipment needs it.assign or it.complete in this company.' using errcode = '42501';
  end if;
  if v_a.returned_at is not null or v_a.issued_at is not null then
    raise exception 'This assignment is not waiting to be issued.';
  end if;
  update public.asset_assignments set issued_at = now(), issued_by = v_me where id = p_assignment_id;
  perform app.set_asset_status(v_a.asset_id, 'assigned');
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
  if not (app.has_capability(v_company, 'it.assign') or app.has_capability(v_company, 'it.complete')) then
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
  if not app.has_capability(v_company, 'it.assign') then
    raise exception 'Cancelling a reservation needs it.assign in this company.' using errcode = '42501';
  end if;
  if v_a.returned_at is not null or v_a.issued_at is not null then
    raise exception 'Only an open reservation can be cancelled.';
  end if;
  delete from public.asset_assignments where id = p_assignment_id;
  perform app.set_asset_status(v_a.asset_id, 'available');
  return jsonb_build_object('status', 'available');
end $$;

-- ------------------------------------------------------------- IT requests
create or replace function app.prepare_it_request() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'open';
    new.blocked_reason := null;
    new.assignee_id := null;
    new.requested_by := coalesce(app.current_person_id(), new.requested_by);
  elsif auth.uid() is not null and current_setting('app.it_transition', true) is distinct from 'on' then
    new.status := old.status;
    new.blocked_reason := old.blocked_reason;
    new.assignee_id := old.assignee_id;
    new.requested_by := old.requested_by;
    new.company_id := old.company_id;
    new.person_id := old.person_id;
  end if;
  new.title := trim(coalesce(new.title, ''));
  if length(new.title) < 2 then
    raise exception 'Enter what is needed.';
  end if;
  if jsonb_typeof(new.requested_systems) <> 'array' then
    raise exception 'Requested systems must be a list.';
  end if;
  if not exists (select 1 from public.employment_periods ep
                 where ep.person_id = new.person_id and ep.company_id = new.company_id) then
    raise exception 'This person has no employment in that company.';
  end if;
  return new;
end $$;
create trigger prepare_it_request before insert or update on public.it_requests
  for each row execute function app.prepare_it_request();

create or replace function public.advance_it_request(
  p_request_id uuid,
  p_status text,
  p_assignee_id uuid default null,
  p_blocked_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_r record;
  v_can_assign boolean;
  v_can_complete boolean;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_r from public.it_requests where id = p_request_id for update;
  if not found then
    raise exception 'Request not found.';
  end if;
  v_can_assign := app.has_capability(v_r.company_id, 'it.assign');
  v_can_complete := v_can_assign or app.has_capability(v_r.company_id, 'it.complete');
  if v_r.status in ('done', 'cancelled') then
    raise exception 'This request is already %.', v_r.status;
  end if;
  if p_status not in ('open', 'in_progress', 'blocked', 'done', 'cancelled') then
    raise exception 'Unknown status: %', p_status;
  end if;
  if p_status = 'done' then
    if not v_can_complete then
      raise exception 'Completing a request needs it.complete in this company.' using errcode = '42501';
    end if;
  elsif not v_can_assign then
    raise exception 'Working a request needs it.assign in this company.' using errcode = '42501';
  end if;
  if p_status = 'blocked' and nullif(trim(coalesce(p_blocked_reason, '')), '') is null then
    raise exception 'Say what blocks it.';
  end if;
  perform set_config('app.it_transition', 'on', true);
  update public.it_requests
    set status = p_status,
        assignee_id = coalesce(p_assignee_id, case when p_status = 'in_progress' and assignee_id is null then v_me else assignee_id end),
        blocked_reason = case when p_status = 'blocked' then trim(p_blocked_reason) else null end
    where id = p_request_id;
  perform set_config('app.it_transition', 'off', true);
  return jsonb_build_object('status', p_status);
end $$;

revoke all on function public.reserve_asset(uuid, uuid, text) from public, anon;
revoke all on function public.issue_asset(uuid) from public, anon;
revoke all on function public.return_asset(uuid, text, text) from public, anon;
revoke all on function public.cancel_reservation(uuid) from public, anon;
revoke all on function public.advance_it_request(uuid, text, uuid, text) from public, anon;
grant execute on function public.reserve_asset(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.issue_asset(uuid) to authenticated, service_role;
grant execute on function public.return_asset(uuid, text, text) to authenticated, service_role;
grant execute on function public.cancel_reservation(uuid) to authenticated, service_role;
grant execute on function public.advance_it_request(uuid, text, uuid, text) to authenticated, service_role;

create trigger audit after insert or update or delete on public.it_requests
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.asset_assignments
  for each row execute function app.audit();
create trigger audit after insert or update or delete on public.assets
  for each row execute function app.audit();
