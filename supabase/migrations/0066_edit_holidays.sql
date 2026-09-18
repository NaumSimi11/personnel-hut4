-- 0066_edit_holidays.sql
-- Renaming a holiday, and moving one to a different date.
--
-- You could already add a holiday and remove one, so a typo or a date the
-- government moved took a delete and a re-add — losing the substitute day that
-- pointed at the old date, silently, because observed_of holds a date and not
-- an id. Nothing said so.
--
-- Both writes are one statement here so a move cannot half-happen, and the
-- clash is named rather than surfacing as a constraint number the panel would
-- print at somebody.

create or replace function public.save_public_holiday(
  p_id uuid, p_date date, p_name text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  h public.public_holidays;
  v_moved int := 0;
begin
  if not (app.is_admin() or app.has_capability_anywhere('holidays.manage')) then
    raise exception 'You need the "Manage holidays" capability.' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Give the holiday a name.';
  end if;
  select * into h from public.public_holidays where id = p_id for update;
  if not found then raise exception 'That holiday no longer exists.'; end if;

  if p_date <> h.date and exists (
    select 1 from public.public_holidays
    where country_code = h.country_code and date = p_date and id <> p_id
  ) then
    raise exception 'There is already a % holiday on %.', h.country_code, to_char(p_date, 'DD Mon YYYY');
  end if;

  -- A substitute day points at its parent by date, so moving the parent has to
  -- take its children with it or they come loose.
  if p_date <> h.date then
    update public.public_holidays
      set observed_of = p_date
      where country_code = h.country_code and observed_of = h.date and id <> p_id;
    get diagnostics v_moved = row_count;
  end if;

  update public.public_holidays set date = p_date, name = trim(p_name) where id = p_id;
  return jsonb_build_object('moved_observed', v_moved);
end $$;
grant execute on function public.save_public_holiday(uuid, date, text) to authenticated;

create or replace function public.save_company_closure(
  p_id uuid, p_date date, p_name text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.company_closures;
begin
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Give the closure a name.';
  end if;
  select * into c from public.company_closures where id = p_id for update;
  if not found then raise exception 'That closure no longer exists.'; end if;
  if not (app.is_admin() or app.has_capability(c.company_id, 'holidays.manage')) then
    raise exception 'You need the "Manage holidays" capability for that company.' using errcode = '42501';
  end if;
  if p_date <> c.date and exists (
    select 1 from public.company_closures
    where company_id = c.company_id and date = p_date and id <> p_id
  ) then
    raise exception 'That company already has a closure on %.', to_char(p_date, 'DD Mon YYYY');
  end if;
  update public.company_closures set date = p_date, name = trim(p_name) where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.save_company_closure(uuid, date, text) to authenticated;
