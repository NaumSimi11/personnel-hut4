-- 0131 — everyone working for the holding has a location (25 Nov).
--
-- 2 of the 37 people working today have one. HR fills them from a company's
-- Structure tab, one dropdown per person; this sets one person's location.
-- The location must be the company's own (or holding-wide), the person must
-- still be working there, and HR needs "Edit employment information". The
-- change is logged by employment_periods' audit trigger.

begin;

create or replace function public.set_employment_location(p_period_id uuid, p_location_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_p public.employment_periods;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_p from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'That employment no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_p.company_id, 'employment.edit') then
    raise exception 'You need "Edit employment information" in this company.' using errcode = '42501';
  end if;
  if v_p.status not in ('active', 'pre_start') then
    raise exception 'Only someone working here, or about to start, gets a location here.' using errcode = '22023';
  end if;
  if p_location_id is not null and not exists (
       select 1 from public.locations l
        where l.id = p_location_id and l.archived_at is null
          and (l.company_id = v_p.company_id or l.company_id is null)) then
    raise exception 'Pick one of this company''s locations.' using errcode = '22023';
  end if;
  update public.employment_periods set location_id = p_location_id where id = p_period_id;
  return jsonb_build_object('period_id', p_period_id, 'location_id', p_location_id);
end $$;

revoke all on function public.set_employment_location(uuid, uuid) from public;
grant execute on function public.set_employment_location(uuid, uuid) to authenticated, service_role;

commit;
