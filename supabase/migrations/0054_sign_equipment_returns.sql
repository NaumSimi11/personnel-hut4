-- 0054_sign_equipment_returns.sql
-- Signing and the act are one statement.
--
-- start_equipment_return and accept_equipment_return now take the signature
-- with them. A return that exists unsigned would be a claim nobody made, and a
-- signature with no return would be a promise about nothing — so neither is
-- reachable: both rows are written in the same transaction or neither is.
--
-- The statement and the capacity are composed HERE, not accepted from the
-- caller. What someone agreed to must not be chosen by the page that asked them
-- to agree to it; otherwise the record says whatever the client felt like.
--
-- The address and browser come from request.headers, which PostgREST fills from
-- the gateway. Not proof of identity — the session already carries that — but
-- it is the ordinary circumstantial record every signing service keeps.

create or replace function app.signing_context() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'ip', coalesce(
      split_part(nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1),
      current_setting('request.headers', true)::json ->> 'cf-connecting-ip'),
    'ua', left(coalesce(current_setting('request.headers', true)::json ->> 'user-agent', ''), 400))
$$;

create or replace function app.record_signature(
  p_subject_type text, p_subject_id uuid, p_person_id uuid,
  p_name text, p_capacity text, p_statement text,
  p_method public.signature_method, p_image text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_ctx jsonb := app.signing_context();
begin
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Type your full name as your signature.';
  end if;
  if p_method = 'drawn' and coalesce(p_image, '') !~ '^data:image/png;base64,' then
    raise exception 'That signature could not be read. Draw it again.';
  end if;
  insert into public.signatures
      (subject_type, subject_id, person_id, signed_name, capacity, statement, method, image, signed_ip, user_agent)
    values (p_subject_type, p_subject_id, p_person_id, trim(p_name), p_capacity, p_statement, p_method,
            case when p_method = 'drawn' then p_image else null end,
            v_ctx ->> 'ip', v_ctx ->> 'ua')
    returning id into v_id;
  return v_id;
end $$;

create or replace function public.start_equipment_return(
  p_asset_id uuid, p_hr_person_id uuid,
  p_sign_name text, p_sign_method public.signature_method default 'typed', p_sign_image text default null,
  p_reason text default null, p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_assignment public.asset_assignments;
  v_asset public.assets;
  v_company uuid;
  v_company_name text;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_asset from public.assets where id = p_asset_id;
  if not found then raise exception 'Asset not found.'; end if;
  select * into v_assignment from public.asset_assignments
    where asset_id = p_asset_id and person_id = v_me and returned_at is null
    order by issued_at desc nulls last limit 1;
  if not found then
    raise exception 'You do not hold this asset.' using errcode = '42501';
  end if;
  if exists (select 1 from public.equipment_returns where asset_id = p_asset_id and status = 'awaiting_hr') then
    raise exception 'A return of this asset is already waiting on HR.';
  end if;

  v_company := coalesce(v_asset.company_id,
    (select ep.company_id from public.employment_periods ep
     join public.employment_statuses es on es.key = ep.status
     where ep.person_id = v_me and es.counts_as_employed order by ep.start_date desc limit 1));
  if v_company is null then
    raise exception 'You have no current employment to file this return against.';
  end if;
  select name into v_company_name from public.companies where id = v_company;

  if not exists (select 1 from public.hr_people(v_company) h where h.id = p_hr_person_id) then
    raise exception 'That person does not handle HR for this company.';
  end if;

  insert into public.equipment_returns
      (asset_id, assignment_id, company_id, person_id, hr_person_id, reason, condition, signed_by_person_at)
    values (p_asset_id, v_assignment.id, v_company, v_me, p_hr_person_id,
            nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_condition, '')), ''), now())
    returning id into v_id;

  perform app.record_signature(
    'equipment_return', v_id, v_me, p_sign_name,
    'The person returning the equipment',
    'I confirm that I have handed back the equipment listed on this form, in the condition recorded, '
      || 'and that I keep nothing further belonging to the company.',
    p_sign_method, p_sign_image);

  perform app.queue_generated_document('equipment_return', v_me, null, 'return:' || v_id);
  perform app.notify(p_hr_person_id, v_company, 'equipment.return_requested',
    app.person_name(v_me) || ' is returning ' || v_asset.asset_tag,
    coalesce(v_asset.model, ''), '/me', 'equipment_return', v_id, 'equipment.return:' || v_id);
  return jsonb_build_object('return_id', v_id);
end $$;
grant execute on function public.start_equipment_return(uuid, uuid, text, public.signature_method, text, text, text) to authenticated;

create or replace function public.accept_equipment_return(
  p_return_id uuid,
  p_sign_name text, p_sign_method public.signature_method default 'typed', p_sign_image text default null,
  p_condition text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  r public.equipment_returns;
  v_company_name text;
begin
  select * into r from public.equipment_returns where id = p_return_id for update;
  if not found then raise exception 'Return not found.'; end if;
  if r.status <> 'awaiting_hr' then
    raise exception 'This return is already %.', r.status;
  end if;
  if not (app.is_self(r.hr_person_id) or app.can_work_asset(r.company_id, 'it.assign')) then
    raise exception 'Only the named HR person may accept this return.' using errcode = '42501';
  end if;
  select name into v_company_name from public.companies where id = r.company_id;

  perform app.record_signature(
    'equipment_return', r.id, v_me, p_sign_name,
    'For ' || coalesce(v_company_name, 'the company'),
    'I confirm that I have received the equipment listed on this form on behalf of '
      || coalesce(v_company_name, 'the company') || ', and that I am authorised to accept it.',
    p_sign_method, p_sign_image);

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
grant execute on function public.accept_equipment_return(uuid, text, public.signature_method, text, text) to authenticated;
