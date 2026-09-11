-- 0015_recruitment_report.sql
-- Recruitment reporting (plan 021). One SECURITY DEFINER function counts in
-- the database so the page never pulls candidate rows to the browser and
-- everyone who may see the numbers sees the same ones. Counts only — no
-- candidate names or PII — gated by jobs.view in the company (blueprint:
-- candidate counts stay available to recruiting users).
--
-- Sources are attributed from applications.source_channel_key; an absent
-- source is reported as "Added by hand", never guessed (blueprint §8).

-- The moment each application was hired: its earliest hired stage event.
create or replace function app.report_hires(company uuid)
returns table (application_id uuid, hired_at timestamptz)
language sql stable security definer set search_path = public as $$
  select e.application_id, min(e.created_at)
  from public.application_events e
  join public.applications a on a.id = e.application_id
  where a.company_id = company
    and e.kind = 'stage_change' and e.to_stage_key = 'hired'
  group by e.application_id
$$;

create or replace function public.recruitment_report(
  p_company_id uuid,
  p_from date,
  p_to date
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamptz;
  v_to timestamptz := (p_to + 1)::timestamptz;  -- inclusive end date
  v_kpis jsonb;
  v_funnel jsonb;
  v_sources jsonb;
  v_attention jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'jobs.view') then
    raise exception 'Viewing recruitment reports requires jobs.view in this company.'
      using errcode = '42501';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date.';
  end if;

  select jsonb_build_object(
    'open_roles', (select count(*) from public.jobs j
                   where j.company_id = p_company_id and j.status = 'open'),
    'active_candidates', (select count(*) from public.applications a
                          join public.jobs j on j.id = a.job_id
                          where a.company_id = p_company_id
                            and j.status in ('open', 'on_hold')
                            and a.stage_key not in ('hired', 'rejected', 'withdrawn')),
    'received', (select count(*) from public.applications a
                 where a.company_id = p_company_id
                   and a.received_at >= v_from and a.received_at < v_to),
    'hires', (select count(*) from app.report_hires(p_company_id) h
              where h.hired_at >= v_from and h.hired_at < v_to),
    'median_days_to_hire', (select round((percentile_cont(0.5) within group (
                              order by extract(epoch from (h.hired_at - a.received_at)) / 86400))::numeric, 1)
                            from app.report_hires(p_company_id) h join public.applications a on a.id = h.application_id
                            where h.hired_at >= v_from and h.hired_at < v_to),
    'avg_days_to_hire', (select round(avg(extract(epoch from (h.hired_at - a.received_at)) / 86400)::numeric, 1)
                         from app.report_hires(p_company_id) h join public.applications a on a.id = h.application_id
                         where h.hired_at >= v_from and h.hired_at < v_to)
  ) into v_kpis;

  -- Funnel per job: every job with an application received in range or
  -- currently open; stage counts are the applications' current stages.
  select coalesce(jsonb_agg(row_to_json(f)::jsonb order by f.received desc, f.title), '[]'::jsonb) into v_funnel
  from (
    select j.id as job_id, j.title, j.status,
           count(a.id) filter (where a.received_at >= v_from and a.received_at < v_to) as received,
           jsonb_build_object(
             'new',        count(a.id) filter (where a.stage_key = 'new'),
             'screening',  count(a.id) filter (where a.stage_key = 'screening'),
             'interview',  count(a.id) filter (where a.stage_key = 'interview'),
             'offer',      count(a.id) filter (where a.stage_key = 'offer'),
             'hired',      count(a.id) filter (where a.stage_key = 'hired'),
             'rejected',   count(a.id) filter (where a.stage_key = 'rejected'),
             'withdrawn',  count(a.id) filter (where a.stage_key = 'withdrawn')
           ) as stages,
           count(a.id) filter (where a.stage_key = 'hired') as hired
    from public.jobs j
    left join public.applications a on a.job_id = j.id
    where j.company_id = p_company_id
    group by j.id, j.title, j.status
    having j.status = 'open'
        or count(a.id) filter (where a.received_at >= v_from and a.received_at < v_to) > 0
  ) f;

  -- Sources: received in range, reached interview or beyond, hired.
  select coalesce(jsonb_agg(row_to_json(s)::jsonb order by s.received desc, s.source), '[]'::jsonb) into v_sources
  from (
    select coalesce(c.label, 'Added by hand') as source,
           count(*) as received,
           count(*) filter (where a.stage_key in ('interview', 'offer', 'hired')
                            or exists (select 1 from public.application_events e
                                       where e.application_id = a.id and e.kind = 'stage_change'
                                         and e.to_stage_key in ('interview', 'offer', 'hired'))) as interviewed,
           count(*) filter (where a.stage_key = 'hired') as hired
    from public.applications a
    left join public.channels c on c.key = a.source_channel_key
    where a.company_id = p_company_id
      and a.received_at >= v_from and a.received_at < v_to
    group by coalesce(c.label, 'Added by hand')
  ) s;

  select jsonb_build_object(
    'overdue_next_actions', (select count(*) from public.applications a
                             where a.company_id = p_company_id
                               and a.stage_key not in ('hired', 'rejected', 'withdrawn')
                               and a.next_action_due is not null and a.next_action_due < current_date),
    'unassigned', (select count(*) from public.applications a
                   join public.jobs j on j.id = a.job_id
                   where a.company_id = p_company_id
                     and j.status = 'open'
                     and a.stage_key not in ('hired', 'rejected', 'withdrawn')
                     and a.owner_id is null),
    'stale', (select count(*) from public.applications a
              join public.jobs j on j.id = a.job_id
              where a.company_id = p_company_id
                and j.status = 'open'
                and a.stage_key not in ('hired', 'rejected', 'withdrawn')
                and coalesce((select max(e.created_at) from public.application_events e
                              where e.application_id = a.id and e.kind = 'stage_change'), a.received_at)
                    < now() - interval '14 days')
  ) into v_attention;

  return jsonb_build_object(
    'company_id', p_company_id,
    'from', p_from, 'to', p_to,
    'kpis', v_kpis, 'funnel', v_funnel, 'sources', v_sources, 'attention', v_attention
  );
end $$;

revoke all on function public.recruitment_report(uuid, date, date) from public, anon;
grant execute on function public.recruitment_report(uuid, date, date) to authenticated, service_role;
