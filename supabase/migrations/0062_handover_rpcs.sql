-- 0062_handover_rpcs.sql
-- The return RPCs, rewritten against asset_handovers, and the same act in the
-- other direction: handing an asset from whoever holds it to somebody else.
--
-- Nothing here is new machinery. A handover is: one party signs that they are
-- giving the thing over, the other signs that they received it, and only then
-- does the asset move. The return already worked that way; reassigning is the
-- same two sentences with the names swapped, so it shares the table, the
-- signature function, the document and the rule that two different people are
-- involved.
--
-- Who signs, and why only two:
--   return    the holder signs (giving), the named HR person signs (receiving)
--   reassign  whoever runs it signs for the company, the receiver signs
--
-- On a reassign the person losing the asset does NOT sign. They are told, and
-- the return form is filed under their name while they still hold it, so the
-- paperwork is theirs. Asking for their signature would mean equipment could
-- not be recovered from somebody on leave, or who has stopped answering — which
-- is exactly when it has to be.

-- Who may run a handover for this asset: IT for the owning company, or, for an
-- asset no company owns, IT anywhere.
create or replace function app.may_hand_over(p_company_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.can_work_asset(p_company_id, 'it.assign')
$$;

-- ---------------------------------------------------------------------------
-- Handing something back. The asset stays with the person until HR signs too.
-- ---------------------------------------------------------------------------
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
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
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

  insert into public.asset_handovers
      (asset_id, company_id, kind, from_person_id, to_person_id, counterparty_id, started_by,
       reason, condition, signed_by_starter_at)
    values (p_asset_id, v_company, 'return', v_me, null, p_hr_person_id, v_me,
            nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  perform app.record_signature(
    'asset_handover', v_id, v_me, p_sign_name,
    'The person returning the equipment',
    'I confirm that I have handed back the equipment listed on this form, in the condition recorded, '
      || 'and that I keep nothing further belonging to the company.',
    p_sign_method, p_sign_image);

  perform app.queue_generated_document('equipment_return', v_me, null, 'handover:' || v_id);
  perform app.notify(p_hr_person_id, v_company, 'equipment.return_requested',
    app.person_name(v_me) || ' is returning ' || v_asset.asset_tag,
    coalesce(v_asset.model, ''), '/me', 'asset_handover', v_id, 'equipment.return:' || v_id);
  return jsonb_build_object('handover_id', v_id, 'return_id', v_id);
end $$;
grant execute on function public.start_equipment_return(uuid, uuid, text, public.signature_method, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Handing it to someone else, from the asset's own page.
-- ---------------------------------------------------------------------------
create or replace function public.start_asset_handover(
  p_asset_id uuid, p_to_person_id uuid,
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
  v_kind text;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_asset from public.assets where id = p_asset_id;
  if not found then raise exception 'Asset not found.'; end if;
  if not app.may_hand_over(v_asset.company_id) then
    raise exception 'You cannot hand out equipment for this company.' using errcode = '42501';
  end if;
  if v_asset.status in ('retired', 'lost') then
    raise exception 'This asset is marked %; put it back in service before handing it over.', v_asset.status;
  end if;

  select person_id into v_holder from public.asset_assignments
    where asset_id = p_asset_id and returned_at is null limit 1;
  if v_holder = p_to_person_id then
    raise exception '% already holds this.', app.person_name(p_to_person_id);
  end if;
  -- Two names on the form, or it records nothing. Issue it the plain way if it
  -- is for yourself.
  if p_to_person_id = v_me then
    raise exception 'Someone else has to hand equipment to you — a form you both sign and start is only your own word.';
  end if;
  if exists (select 1 from public.asset_handovers where asset_id = p_asset_id and status = 'awaiting') then
    raise exception 'This asset is already part of a handover waiting to be signed.';
  end if;

  v_company := coalesce(v_asset.company_id,
    (select ep.company_id from public.employment_periods ep
     join public.employment_statuses es on es.key = ep.status
     where ep.person_id = p_to_person_id and es.counts_as_employed order by ep.start_date desc limit 1));
  if v_company is null then
    raise exception 'That person has no current employment to file this handover against.';
  end if;
  if not exists (
    select 1 from public.employment_periods ep
    join public.employment_statuses es on es.key = ep.status
    where ep.person_id = p_to_person_id and ep.company_id = v_company and es.counts_as_employed
  ) then
    raise exception 'That person does not currently work at this company.';
  end if;
  select name into v_company_name from public.companies where id = v_company;
  v_kind := case when v_holder is null then 'issue' else 'reassign' end;

  insert into public.asset_handovers
      (asset_id, company_id, kind, from_person_id, to_person_id, counterparty_id, started_by,
       reason, condition, signed_by_starter_at)
    values (p_asset_id, v_company, v_kind, v_holder, p_to_person_id, p_to_person_id, v_me,
            nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  perform app.record_signature(
    'asset_handover', v_id, v_me, p_sign_name,
    'For ' || coalesce(v_company_name, 'the company'),
    'I confirm that I am handing over the equipment listed on this form on behalf of '
      || coalesce(v_company_name, 'the company') || ', that I am authorised to do so, and that the '
      || 'record of who held it before is correct.',
    p_sign_method, p_sign_image);

  -- The outgoing holder's own copy, filed while they still hold it so the form
  -- actually lists the thing they are giving up.
  if v_holder is not null then
    perform app.queue_generated_document('equipment_return', v_holder, null, 'handover:' || v_id || ':out');
    perform app.notify(v_holder, v_company, 'equipment.taken_back',
      v_asset.asset_tag || ' is being handed to ' || app.person_name(p_to_person_id),
      coalesce(v_asset.model, ''), '/me', 'asset_handover', v_id, 'equipment.out:' || v_id);
  end if;

  perform app.notify(p_to_person_id, v_company, 'equipment.handover_offered',
    app.person_name(v_me) || ' is handing you ' || v_asset.asset_tag,
    coalesce(v_asset.model, ''), '/me', 'asset_handover', v_id, 'equipment.in:' || v_id);
  return jsonb_build_object('handover_id', v_id, 'kind', v_kind);
end $$;
grant execute on function public.start_asset_handover(uuid, uuid, text, public.signature_method, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- The second signature. Only now does the asset actually move.
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
          or (h.kind = 'return' and app.can_work_asset(h.company_id, 'it.assign'))) then
    raise exception 'Only %s may sign this handover.', app.person_name(h.counterparty_id)
      using errcode = '42501';
  end if;
  select name into v_company_name from public.companies where id = h.company_id;
  select asset_tag into v_tag from public.assets where id = h.asset_id;
  v_condition := coalesce(nullif(trim(coalesce(p_condition, '')), ''), h.condition);

  if h.kind = 'return' then
    perform app.record_signature(
      'asset_handover', h.id, v_me, p_sign_name,
      'For ' || coalesce(v_company_name, 'the company'),
      'I confirm that I have received the equipment listed on this form on behalf of '
        || coalesce(v_company_name, 'the company') || ', and that I am authorised to accept it.',
      p_sign_method, p_sign_image);
  else
    perform app.record_signature(
      'asset_handover', h.id, v_me, p_sign_name,
      'The person receiving the equipment',
      'I confirm that I have received the equipment listed on this form, that I have checked its '
        || 'condition, and that I will return it on request or when I leave.',
      p_sign_method, p_sign_image);
  end if;

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

  if h.kind = 'return' then
    perform app.notify(h.from_person_id, h.company_id, 'equipment.return_accepted',
      'Your equipment return was accepted', '', '/me', 'asset_handover', h.id,
      'equipment.return_accepted:' || h.id);
  else
    -- Now that they hold it, their handover form lists it.
    perform app.queue_generated_document('equipment_handover', h.to_person_id, null, 'handover:' || h.id || ':in');
    perform app.notify(h.started_by, h.company_id, 'equipment.handover_accepted',
      app.person_name(h.to_person_id) || ' signed for ' || coalesce(v_tag, 'the equipment'),
      '', '/equipment', 'asset_handover', h.id, 'equipment.accepted:' || h.id);
  end if;
  return jsonb_build_object('status', 'accepted');
end $$;
grant execute on function public.accept_asset_handover(uuid, text, public.signature_method, text, text) to authenticated;

-- The old name, kept so the return card keeps working.
create or replace function public.accept_equipment_return(
  p_return_id uuid,
  p_sign_name text, p_sign_method public.signature_method default 'typed', p_sign_image text default null,
  p_condition text default null
) returns jsonb
language sql security definer set search_path = public as $$
  select public.accept_asset_handover(p_return_id, p_sign_name, p_sign_method, p_sign_image, p_condition)
$$;
grant execute on function public.accept_equipment_return(uuid, text, public.signature_method, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Saying no, and thinking better of it.
-- ---------------------------------------------------------------------------
create or replace function public.decline_asset_handover(p_handover_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  h public.asset_handovers;
begin
  select * into h from public.asset_handovers where id = p_handover_id for update;
  if not found then raise exception 'Handover not found.'; end if;
  if h.status <> 'awaiting' then
    raise exception 'This handover is already %.', h.status;
  end if;
  if not (app.is_self(h.counterparty_id)
          or (h.kind = 'return' and app.can_work_asset(h.company_id, 'it.assign'))) then
    raise exception 'Only %s may decline this handover.', app.person_name(h.counterparty_id)
      using errcode = '42501';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Give the reason, so the other side knows what to do next.';
  end if;

  -- The asset never moved, so declining only closes the request.
  update public.asset_handovers
    set status = 'declined', decline_reason = trim(p_reason),
        signed_by_counterparty = v_me, signed_by_counterparty_at = now()
    where id = p_handover_id;

  perform app.notify(h.started_by, h.company_id, 'equipment.handover_declined',
    case when h.kind = 'return' then 'Your equipment return was not accepted'
         else app.person_name(v_me) || ' did not accept the equipment' end,
    trim(p_reason), '/me', 'asset_handover', h.id, 'equipment.declined:' || h.id);
  return jsonb_build_object('status', 'declined');
end $$;
grant execute on function public.decline_asset_handover(uuid, text) to authenticated;

create or replace function public.decline_equipment_return(p_return_id uuid, p_reason text)
returns jsonb language sql security definer set search_path = public as $$
  select public.decline_asset_handover(p_return_id, p_reason)
$$;
grant execute on function public.decline_equipment_return(uuid, text) to authenticated;

create or replace function public.cancel_asset_handover(p_handover_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h public.asset_handovers;
begin
  select * into h from public.asset_handovers where id = p_handover_id for update;
  if not found then raise exception 'Handover not found.'; end if;
  if not app.is_self(h.started_by) then
    raise exception 'Only whoever started this handover may withdraw it.' using errcode = '42501';
  end if;
  if h.status <> 'awaiting' then
    raise exception 'This handover is already %.', h.status;
  end if;
  update public.asset_handovers set status = 'cancelled' where id = p_handover_id;
  return jsonb_build_object('status', 'cancelled');
end $$;
grant execute on function public.cancel_asset_handover(uuid) to authenticated;

create or replace function public.cancel_equipment_return(p_return_id uuid) returns jsonb
language sql security definer set search_path = public as $$
  select public.cancel_asset_handover(p_return_id)
$$;
grant execute on function public.cancel_equipment_return(uuid) to authenticated;

-- Who this asset may be handed to: everyone currently employed by the company
-- that owns it, minus whoever already holds it. Read as a function because the
-- asset page's reader may not be allowed to list a company's whole staff.
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
    and p.id not in (select person_id from public.asset_assignments
                     where asset_id = p_asset_id and returned_at is null)
  order by p.full_name
$$;
grant execute on function public.handover_candidates(uuid) to authenticated;

-- The pre-signature overloads from 0051 named a table that no longer exists.
-- Left in place they would be reachable by argument shape and fail obscurely.
drop function if exists public.start_equipment_return(uuid, uuid, text, text);
drop function if exists public.accept_equipment_return(uuid, text);
