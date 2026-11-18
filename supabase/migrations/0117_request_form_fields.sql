-- 0117: the hiring request names its department, hiring manager, location
-- and employment type (decision D15).
--
-- Department and hiring manager were optional, so a request could go to
-- approval with only a title and a headcount. D15: both are required, and
-- the form gains location and employment type (recorded, not required).
--
-- Required is enforced whenever a signed-in user submits — a new request, a
-- revision resubmitted, or an approved one sent back by amend_hiring_request
-- (the session role stays "authenticated" inside a security definer
-- function) — so no door around the form skips it. Service jobs and imports,
-- which do not run as a signed-in user, are left alone, as are requests
-- already in flight.

begin;

alter table public.hiring_requests
  add column location_id uuid references public.locations(id),
  add column employment_type_key text references public.employment_types(key);

create or replace function app.request_needs_its_fields() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status = 'submitted'
     and (tg_op = 'INSERT' or old.status is distinct from 'submitted')
     and current_setting('role', true) = 'authenticated' then
    if new.department_id is null then
      raise exception 'Choose the department this hire is for.' using errcode = '23502';
    end if;
    if new.hiring_manager_id is null then
      raise exception 'Choose the hiring manager for this hire.' using errcode = '23502';
    end if;
  end if;
  return new;
end $$;

create trigger t2_request_needs_its_fields before insert or update on public.hiring_requests
  for each row execute function app.request_needs_its_fields();

-- 0110's amendment, now also carrying location and employment type.
create or replace function public.amend_hiring_request(p_request_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req public.hiring_requests := app.request_for_lifecycle(p_request_id);
  v_title text := coalesce(nullif(trim(p->>'title'), ''), v_req.title);
  v_reason text := case when p ? 'reason' then nullif(trim(p->>'reason'), '') else v_req.reason end;
  v_headcount int := coalesce(nullif(p->>'headcount', '')::int, v_req.headcount);
  v_start date := case when p ? 'target_start_date' then nullif(p->>'target_start_date', '')::date else v_req.target_start_date end;
  v_hm uuid := case when p ? 'hiring_manager_id' then nullif(p->>'hiring_manager_id', '')::uuid else v_req.hiring_manager_id end;
  v_budget jsonb := case when p ? 'budget' then nullif(p->'budget', 'null'::jsonb) else v_req.budget end;
  v_department uuid := case when p ? 'department_id' then nullif(p->>'department_id', '')::uuid else v_req.department_id end;
  v_location uuid := case when p ? 'location_id' then nullif(p->>'location_id', '')::uuid else v_req.location_id end;
  v_type text := case when p ? 'employment_type_key' then nullif(p->>'employment_type_key', '') else v_req.employment_type_key end;
  v_major boolean;
begin
  if v_req.status <> 'approved' then
    raise exception 'Only an approved request is amended here.' using errcode = '22023';
  end if;
  if v_headcount < 1 then
    raise exception 'Headcount must be at least 1.' using errcode = '22023';
  end if;
  v_major := (v_title, v_reason, v_headcount, v_budget) is distinct from (v_req.title, v_req.reason, v_req.headcount, v_req.budget);
  perform set_config('app.request_lifecycle', 'on', true);
  update public.hiring_requests
     set title = v_title, reason = v_reason, headcount = v_headcount, target_start_date = v_start,
         hiring_manager_id = v_hm, budget = v_budget, department_id = v_department,
         location_id = v_location, employment_type_key = v_type,
         status = case when v_major then 'submitted' else status end,
         decided_by = case when v_major then null else decided_by end,
         decided_at = case when v_major then null else decided_at end
   where id = v_req.id;
  perform set_config('app.request_lifecycle', 'off', true);
  return jsonb_build_object('status', case when v_major then 'submitted' else 'approved' end, 'reapproval', v_major);
end $$;
grant execute on function public.amend_hiring_request(uuid, jsonb) to authenticated;

commit;
