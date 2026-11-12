-- 0111_hiring_dashboard.sql
-- The hiring dashboard (Hiring Module user flows, 11 Nov 2026: screen 9.14,
-- "open requests by status and department, time to fill, time to hire, offer
-- acceptance rate"). Time to hire is already in recruitment_report (0096);
-- this adds the rest for the same company and date range.
--
--   * A request may name the department it hires for (optional).
--   * Time to fill: days from a job's opening to the hire that filled it,
--     for jobs filled within the range.
--   * Offer acceptance: offers answered within the range, accepted out of
--     accepted plus declined.

begin;

alter table public.hiring_requests add column department_id uuid references public.departments(id);

create or replace function public.hiring_dashboard(p_company_id uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamptz;
  v_to timestamptz := (p_to + 1)::timestamptz;
  v_requests jsonb;
  v_fill jsonb;
  v_offers jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'jobs.view') then
    raise exception 'Viewing the hiring dashboard requires jobs.view in this company.' using errcode = '42501';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('status', x.status, 'department', x.department, 'count', x.n)
                            order by x.status, x.department), '[]'::jsonb)
    into v_requests
    from (select r.status, coalesce(d.name, 'No department') as department, count(*) as n
            from public.hiring_requests r
            left join public.departments d on d.id = r.department_id
           where r.company_id = p_company_id
             and r.status in ('draft', 'submitted', 'changes_requested', 'approved', 'on_hold')
           group by r.status, coalesce(d.name, 'No department')) x;

  with filled as (
    select j.id, j.opened_at,
           (select max(e.created_at) from public.application_events e
              join public.applications a on a.id = e.application_id
             where a.job_id = j.id and e.to_stage_key = 'hired') as filled_at
      from public.jobs j
     where j.company_id = p_company_id and j.status = 'filled' and j.opened_at is not null
  ), days as (
    select extract(epoch from (filled_at - opened_at)) / 86400 as d
      from filled where filled_at >= v_from and filled_at < v_to and filled_at >= opened_at
  )
  select jsonb_build_object(
           'jobs', count(*),
           'median_days', round((percentile_cont(0.5) within group (order by d))::numeric, 1),
           'avg_days', round(avg(d)::numeric, 1))
    into v_fill from days;

  select jsonb_build_object(
           'accepted', count(*) filter (where o.status = 'accepted'),
           'declined', count(*) filter (where o.status = 'declined'),
           'rate', case when count(*) filter (where o.status in ('accepted', 'declined')) = 0 then null
                        else round(100.0 * count(*) filter (where o.status = 'accepted')
                                   / count(*) filter (where o.status in ('accepted', 'declined')), 0) end)
    into v_offers
    from public.offers o
   where o.company_id = p_company_id and o.status in ('accepted', 'declined')
     and coalesce(o.answered_by_candidate_at, o.accepted_at, o.updated_at) >= v_from
     and coalesce(o.answered_by_candidate_at, o.accepted_at, o.updated_at) < v_to;

  return jsonb_build_object('company_id', p_company_id, 'from', p_from, 'to', p_to,
                            'open_requests', v_requests, 'time_to_fill', v_fill, 'offers', v_offers);
end $$;
grant execute on function public.hiring_dashboard(uuid, date, date) to authenticated;

-- 0110's amend, carrying the department (a minor field: no new approval).
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
         status = case when v_major then 'submitted' else status end,
         decided_by = case when v_major then null else decided_by end,
         decided_at = case when v_major then null else decided_at end
   where id = v_req.id;
  perform set_config('app.request_lifecycle', 'off', true);
  return jsonb_build_object('status', case when v_major then 'submitted' else 'approved' end, 'reapproval', v_major);
end $$;
grant execute on function public.amend_hiring_request(uuid, jsonb) to authenticated;

commit;
