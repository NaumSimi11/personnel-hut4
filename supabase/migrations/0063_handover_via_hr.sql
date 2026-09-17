-- 0063_handover_via_hr.sql
-- Equipment never passes from one employee straight to another.
--
-- 0062 let IT move an asset from Ana to Marko in a single signed act. That is
-- not how the company works: you hand a thing back to HR, HR gives it out
-- again. Two acts, two forms, and in between the thing is in magacin where the
-- register can see it. Collapsing them hid the moment when nobody held it,
-- which is exactly the moment somebody is accountable for checking it.
--
-- So 'reassign' goes, and the one function that did it becomes two that cannot
-- be the wrong one:
--
--   take_asset_back   the asset has a holder; it goes back to magacin, and the
--                     holder is the one who signs that they handed it over
--   hand_asset_out    the asset has no holder; it goes to a person, and that
--                     person signs that they received it
--
-- Neither is reachable in the other's situation, so the round trip through
-- magacin is the shape of the API rather than a rule somebody has to remember.

alter table public.asset_handovers drop constraint asset_handovers_kind_check;
alter table public.asset_handovers add constraint asset_handovers_kind_check
  check (kind in ('return', 'issue'));

-- ---------------------------------------------------------------------------
-- What each side is putting their name to.
--
-- Composed here, in one place, so the two starts and the one accept cannot
-- drift apart. Which sentence you get follows from where you stand in the
-- handover, not from which button was pressed — the same person signs the same
-- words whether HR asked for the thing back or they offered it.
-- ---------------------------------------------------------------------------
create or replace function app.handover_side(h public.asset_handovers, p_person uuid) returns text
language sql immutable as $$
  select case
    when p_person = h.from_person_id then 'returning'
    when p_person = h.to_person_id then 'receiving'
    when h.to_person_id is null then 'receivingForCompany'
    else 'handingOver'
  end
$$;

create or replace function app.handover_statement(p_side text, p_company text) returns text
language sql immutable as $$
  select case p_side
    when 'returning' then
      'I confirm that I have handed back the equipment listed on this form, in the condition '
      || 'recorded, and that I keep nothing further belonging to the company.'
    when 'receivingForCompany' then
      'I confirm that I have received the equipment listed on this form on behalf of ' || p_company
      || ', and that I am authorised to accept it.'
    when 'handingOver' then
      'I confirm that I am handing over the equipment listed on this form on behalf of ' || p_company
      || ', that I am authorised to do so, and that the record of who held it before is correct.'
    when 'recalling' then
      'I confirm that I am asking for the equipment listed on this form back on behalf of ' || p_company
      || ', and that I am authorised to do so.'
    else
      'I confirm that I have received the equipment listed on this form, that I have checked its '
      || 'condition, and that I will return it on request or when I leave.'
  end
$$;

create or replace function app.handover_capacity(p_side text, p_company text) returns text
language sql immutable as $$
  select case p_side
    when 'returning' then 'The person returning the equipment'
    when 'receiving' then 'The person receiving the equipment'
    else 'For ' || p_company
  end
$$;

-- ---------------------------------------------------------------------------
-- HR asks for something back. It stays with the person until they sign.
-- ---------------------------------------------------------------------------
create or replace function public.take_asset_back(
  p_asset_id uuid,
  p_sign_name text, p_sign_method public.signature_method default 'typed', p_sign_image text default null,
  p_reason text default null, p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_asset public.assets;
  v_holder uuid;
  v_company uuid;
  v_company_name text;
  v_id uuid;
begin
  if v_me is null then raise exception 'Sign in to continue.' using errcode = '42501'; end if;
  select * into v_asset from public.assets where id = p_asset_id;
  if not found then raise exception 'Asset not found.'; end if;
  if not app.may_hand_over(v_asset.company_id) then
    raise exception 'You cannot move equipment for this company.' using errcode = '42501';
  end if;

  select person_id into v_holder from public.asset_assignments
    where asset_id = p_asset_id and returned_at is null limit 1;
  if v_holder is null then
    raise exception 'Nobody holds this, so there is nothing to take back.';
  end if;
  if v_holder = v_me then
    raise exception 'This is yours — hand it back from your own page, so somebody else receives it.';
  end if;
  if exists (select 1 from public.asset_handovers where asset_id = p_asset_id and status = 'awaiting') then
    raise exception 'This asset is already part of a handover waiting to be signed.';
  end if;

  v_company := coalesce(v_asset.company_id,
    (select ep.company_id from public.employment_periods ep
     join public.employment_statuses es on es.key = ep.status
     where ep.person_id = v_holder and es.counts_as_employed order by ep.start_date desc limit 1));
  if v_company is null then
    raise exception 'There is no company to file this against.';
  end if;
  select name into v_company_name from public.companies where id = v_company;

  insert into public.asset_handovers
      (asset_id, company_id, kind, from_person_id, to_person_id, counterparty_id, started_by,
       reason, condition, signed_by_starter_at)
    values (p_asset_id, v_company, 'return', v_holder, null, v_holder, v_me,
            nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  perform app.record_signature('asset_handover', v_id, v_me, p_sign_name,
    app.handover_capacity('recalling', v_company_name),
    app.handover_statement('recalling', v_company_name),
    p_sign_method, p_sign_image);

  perform app.notify(v_holder, v_company, 'equipment.recall_requested',
    app.person_name(v_me) || ' is asking for ' || v_asset.asset_tag || ' back',
    coalesce(v_asset.model, ''), '/me', 'asset_handover', v_id, 'equipment.recall:' || v_id);
  return jsonb_build_object('handover_id', v_id, 'kind', 'return');
end $$;
grant execute on function public.take_asset_back(uuid, text, public.signature_method, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- HR gives something out. It stays in magacin until the person signs.
-- ---------------------------------------------------------------------------
create or replace function public.hand_asset_out(
  p_asset_id uuid, p_to_person_id uuid,
  p_sign_name text, p_sign_method public.signature_method default 'typed', p_sign_image text default null,
  p_reason text default null, p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_asset public.assets;
  v_company uuid;
  v_company_name text;
  v_id uuid;
begin
  if v_me is null then raise exception 'Sign in to continue.' using errcode = '42501'; end if;
  select * into v_asset from public.assets where id = p_asset_id;
  if not found then raise exception 'Asset not found.'; end if;
  if not app.may_hand_over(v_asset.company_id) then
    raise exception 'You cannot hand out equipment for this company.' using errcode = '42501';
  end if;
  if v_asset.status in ('retired', 'lost') then
    raise exception 'This asset is marked %; put it back in service before handing it out.', v_asset.status;
  end if;
  if exists (select 1 from public.asset_assignments where asset_id = p_asset_id and returned_at is null) then
    raise exception 'Somebody still holds this. Take it back first — equipment does not pass from one person straight to another.';
  end if;
  if p_to_person_id = v_me then
    raise exception 'Someone else has to hand equipment to you — a form you both start and sign is only your own word.';
  end if;
  if exists (select 1 from public.asset_handovers where asset_id = p_asset_id and status = 'awaiting') then
    raise exception 'This asset is already part of a handover waiting to be signed.';
  end if;

  v_company := coalesce(v_asset.company_id,
    (select ep.company_id from public.employment_periods ep
     join public.employment_statuses es on es.key = ep.status
     where ep.person_id = p_to_person_id and es.counts_as_employed order by ep.start_date desc limit 1));
  if v_company is null then
    raise exception 'That person has no current employment to file this against.';
  end if;
  if not exists (
    select 1 from public.employment_periods ep
    join public.employment_statuses es on es.key = ep.status
    where ep.person_id = p_to_person_id and ep.company_id = v_company and es.counts_as_employed
  ) then
    raise exception 'That person does not currently work at this company.';
  end if;
  select name into v_company_name from public.companies where id = v_company;

  insert into public.asset_handovers
      (asset_id, company_id, kind, from_person_id, to_person_id, counterparty_id, started_by,
       reason, condition, signed_by_starter_at)
    values (p_asset_id, v_company, 'issue', null, p_to_person_id, p_to_person_id, v_me,
            nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  perform app.record_signature('asset_handover', v_id, v_me, p_sign_name,
    app.handover_capacity('handingOver', v_company_name),
    app.handover_statement('handingOver', v_company_name),
    p_sign_method, p_sign_image);

  perform app.notify(p_to_person_id, v_company, 'equipment.handover_offered',
    app.person_name(v_me) || ' is handing you ' || v_asset.asset_tag,
    coalesce(v_asset.model, ''), '/me', 'asset_handover', v_id, 'equipment.in:' || v_id);
  return jsonb_build_object('handover_id', v_id, 'kind', 'issue');
end $$;
grant execute on function public.hand_asset_out(uuid, uuid, text, public.signature_method, text, text, text) to authenticated;

-- The one-step reassign is gone.
drop function if exists public.start_asset_handover(uuid, uuid, text, public.signature_method, text, text, text);

-- ---------------------------------------------------------------------------
-- The second signature, now reading its words off which side you stand on.
-- ---------------------------------------------------------------------------
create or replace function public.accept_asset_handover(
  p_handover_id uuid,
  p_sign_name text, p_sign_method public.signature_method default 'typed', p_sign_image text default null,
  p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  h public.asset_handovers;
  v_company_name text;
  v_tag text;
  v_condition text;
  v_side text;
begin
  select * into h from public.asset_handovers where id = p_handover_id for update;
  if not found then raise exception 'Handover not found.'; end if;
  if h.status <> 'awaiting' then
    raise exception 'This handover is already %.', h.status;
  end if;
  if h.started_by = v_me then
    raise exception 'You started this handover — the other side has to sign for it.';
  end if;
  if not (app.is_self(h.counterparty_id)
          or (h.to_person_id is null and app.can_work_asset(h.company_id, 'it.assign'))) then
    raise exception 'Only % may sign this handover.', app.person_name(h.counterparty_id)
      using errcode = '42501';
  end if;
  select name into v_company_name from public.companies where id = h.company_id;
  select asset_tag into v_tag from public.assets where id = h.asset_id;
  v_condition := coalesce(nullif(trim(coalesce(p_condition, '')), ''), h.condition);
  v_side := app.handover_side(h, v_me);

  perform app.record_signature('asset_handover', h.id, v_me, p_sign_name,
    app.handover_capacity(v_side, v_company_name),
    app.handover_statement(v_side, v_company_name),
    p_sign_method, p_sign_image);

  -- Close whoever held it, then open the new holder. In that order: one open
  -- assignment per asset is a unique index, not a wish.
  update public.asset_assignments
    set returned_at = now(), return_condition = v_condition
    where asset_id = h.asset_id and returned_at is null;

  if h.to_person_id is null then
    perform app.set_asset_status(h.asset_id, 'available');
  else
    insert into public.asset_assignments (asset_id, person_id, issued_at, issued_by, note)
      values (h.asset_id, h.to_person_id, now(), h.started_by, h.reason);
    perform app.set_asset_status(h.asset_id, 'assigned');
    -- The books named a holder we could never match; a real one now supersedes it.
    update public.assets set holder_note = null where id = h.asset_id and holder_note is not null;
  end if;

  update public.asset_handovers
    set status = 'accepted', signed_by_counterparty_at = now(), signed_by_counterparty = v_me,
        condition = v_condition
    where id = p_handover_id;

  if h.to_person_id is null then
    -- Back in magacin. Tell the person whose name came off it, and the HR side,
    -- which routes to the company's HR inbox when one is set.
    perform app.notify(h.from_person_id, h.company_id, 'equipment.return_accepted',
      coalesce(v_tag, 'The equipment') || ' is back in magacin', '', '/me',
      'asset_handover', h.id, 'equipment.return_accepted:' || h.id);
    perform app.notify(h.started_by, h.company_id, 'equipment.return_settled',
      coalesce(v_tag, 'Equipment') || ' came back from ' || app.person_name(h.from_person_id),
      '', '/equipment', 'asset_handover', h.id, 'equipment.settled:' || h.id, true);
  else
    -- Now that they hold it, their handover form lists it.
    perform app.queue_generated_document('equipment_handover', h.to_person_id, null, 'handover:' || h.id || ':in');
    perform app.notify(h.started_by, h.company_id, 'equipment.handover_accepted',
      app.person_name(h.to_person_id) || ' signed for ' || coalesce(v_tag, 'the equipment'),
      '', '/equipment', 'asset_handover', h.id, 'equipment.accepted:' || h.id, true);
  end if;
  return jsonb_build_object('status', 'accepted');
end $$;
grant execute on function public.accept_asset_handover(uuid, text, public.signature_method, text, text) to authenticated;

-- A take-back queues the person's return form at the moment they sign it off,
-- so the form lists what they actually handed over.
create or replace function app.queue_return_form_on_recall() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'accepted' and old.status = 'awaiting'
     and new.to_person_id is null and new.from_person_id is not null then
    perform app.queue_generated_document('equipment_return', new.from_person_id, null, 'handover:' || new.id || ':out');
  end if;
  return new;
end $$;
drop trigger if exists queue_return_form on public.asset_handovers;
create trigger queue_return_form before update on public.asset_handovers
  for each row execute function app.queue_return_form_on_recall();

-- The HR side is told when somebody starts a return, at the company's HR inbox
-- when one is set rather than only the named person's own mail.
create or replace function public.start_equipment_return(
  p_asset_id uuid, p_hr_person_id uuid,
  p_sign_name text, p_sign_method public.signature_method default 'typed', p_sign_image text default null,
  p_reason text default null, p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_asset public.assets;
  v_company uuid;
  v_company_name text;
  v_id uuid;
begin
  if v_me is null then raise exception 'Sign in to continue.' using errcode = '42501'; end if;
  if p_hr_person_id = v_me then
    raise exception 'Choose someone else in HR — you cannot hand equipment back to yourself.';
  end if;
  select * into v_asset from public.assets where id = p_asset_id;
  if not found then raise exception 'Asset not found.'; end if;
  if not exists (select 1 from public.asset_assignments
                 where asset_id = p_asset_id and person_id = v_me and returned_at is null) then
    raise exception 'You do not hold this asset.' using errcode = '42501';
  end if;
  if exists (select 1 from public.asset_handovers where asset_id = p_asset_id and status = 'awaiting') then
    raise exception 'This asset is already part of a handover waiting to be signed.';
  end if;

  v_company := coalesce(v_asset.company_id,
    (select ep.company_id from public.employment_periods ep
     join public.employment_statuses es on es.key = ep.status
     where ep.person_id = v_me and es.counts_as_employed order by ep.start_date desc limit 1));
  if v_company is null then
    raise exception 'You have no current employment to file this return against.';
  end if;
  if not exists (select 1 from public.hr_people(v_company) h where h.id = p_hr_person_id) then
    raise exception 'That person does not handle HR for this company.';
  end if;
  select name into v_company_name from public.companies where id = v_company;

  insert into public.asset_handovers
      (asset_id, company_id, kind, from_person_id, to_person_id, counterparty_id, started_by,
       reason, condition, signed_by_starter_at)
    values (p_asset_id, v_company, 'return', v_me, null, p_hr_person_id, v_me,
            nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  perform app.record_signature('asset_handover', v_id, v_me, p_sign_name,
    app.handover_capacity('returning', v_company_name),
    app.handover_statement('returning', v_company_name),
    p_sign_method, p_sign_image);

  perform app.queue_generated_document('equipment_return', v_me, null, 'handover:' || v_id || ':out');
  perform app.notify(p_hr_person_id, v_company, 'equipment.return_requested',
    app.person_name(v_me) || ' is returning ' || v_asset.asset_tag,
    coalesce(v_asset.model, ''), '/me', 'asset_handover', v_id, 'equipment.return:' || v_id, true);
  return jsonb_build_object('handover_id', v_id, 'return_id', v_id);
end $$;
grant execute on function public.start_equipment_return(uuid, uuid, text, public.signature_method, text, text, text) to authenticated;

-- Only offered for an asset nobody holds: you cannot pick a new person for
-- something that is still with somebody.
create or replace function public.handover_candidates(p_asset_id uuid)
returns table (id uuid, full_name text, job_title text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.full_name, ep.job_title
  from public.assets a
  join public.employment_periods ep
    on ep.company_id = coalesce(a.company_id, ep.company_id)
  join public.employment_statuses es on es.key = ep.status and es.counts_as_employed
  join public.people p on p.id = ep.person_id
  where a.id = p_asset_id
    and app.may_hand_over(a.company_id)
    and not exists (select 1 from public.asset_assignments
                    where asset_id = p_asset_id and returned_at is null)
  order by p.full_name
$$;
grant execute on function public.handover_candidates(uuid) to authenticated;
