-- 0132 — a location is typed in, not picked from a list (25 Nov).
--
-- People work from Struga, Skopje, Lithuania… so HR types the place. A typed
-- name becomes the company's location of that name (any case, single
-- spaces): an existing one is reused, a new one is made. New-hire notices
-- and reports keep reading locations as before.

begin;

/** The company's location with this name, made when there is none. */
create or replace function public.ensure_location(p_company_id uuid, p_name text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_id uuid;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'employment.edit') then
    raise exception 'You need "Edit employment information" in this company.' using errcode = '42501';
  end if;
  if length(v_name) < 2 or length(v_name) > 80 then
    raise exception 'Type where they work, e.g. Skopje, Struga or Vilnius, Lithuania.' using errcode = '22023';
  end if;
  select id into v_id from public.locations
   where archived_at is null and (company_id = p_company_id or company_id is null)
     and lower(name) = lower(v_name)
   order by (company_id is null), name
   limit 1;
  if v_id is null then
    insert into public.locations (company_id, name) values (p_company_id, v_name)
    on conflict (company_id, name) do update set archived_at = null
    returning id into v_id;
  end if;
  return v_id;
end $$;

/** Type a person's location: the company's location of that name, set on their employment. */
create or replace function public.set_employment_location_name(p_period_id uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid;
  v_loc uuid;
begin
  select company_id into v_company from public.employment_periods where id = p_period_id;
  if v_company is null then
    raise exception 'That employment no longer exists.' using errcode = '22023';
  end if;
  v_loc := public.ensure_location(v_company, p_name);
  return public.set_employment_location(p_period_id, v_loc) || jsonb_build_object('name', (select name from public.locations where id = v_loc));
end $$;

revoke all on function public.ensure_location(uuid, text) from public;
revoke all on function public.set_employment_location_name(uuid, text) from public;
grant execute on function public.ensure_location(uuid, text) to authenticated, service_role;
grant execute on function public.set_employment_location_name(uuid, text) to authenticated, service_role;

commit;
