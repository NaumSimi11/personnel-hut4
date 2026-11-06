-- 0097_hiring_summary_and_import.sql
--
-- Part 1 (egress): the Home page and the Openings panel counted by downloading
-- every application (thousands of rows, paged past PostgREST's 1,000 cap). The
-- database returns the counts instead. Part 2 (the Zoho CSV import function)
-- is appended below by a later task.

begin;

-- ============================================================ Part 1: summaries

-- ---------------------------------------------------------------- hiring_summary
-- What Home's recruitment block draws, counted in the database and limited to
-- the companies where the caller holds candidates.view:
--   by_job         applications on ready/open/on_hold jobs, per job, stage and in_play
--   not_responding applications app.not_responding flags (the report's rule)
--   recent         the five newest applications still in play
create or replace function public.hiring_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_visible uuid[];
  v_by_job jsonb;
  v_not_responding bigint;
  v_recent jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  select coalesce(array_agg(c.id), '{}') into v_visible
    from public.companies c where app.has_capability(c.id, 'candidates.view');

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', g.job_id, 'stage_key', g.stage_key, 'in_play', g.in_play,
           'count', g.n, 'last_received_at', g.last_received_at)
         order by g.job_id, g.stage_key, g.in_play desc), '[]'::jsonb) into v_by_job
    from (
      select a.job_id, a.stage_key, a.in_play, count(*) as n, max(a.received_at) as last_received_at
        from public.applications a
        join public.jobs j on j.id = a.job_id
       where a.company_id = any (v_visible)
         and j.status in ('ready', 'open', 'on_hold')
       group by a.job_id, a.stage_key, a.in_play
    ) g;

  select count(*) into v_not_responding
    from public.applications a
   where a.company_id = any (v_visible) and a.in_play and app.not_responding(a);

  select coalesce(jsonb_agg(jsonb_build_object(
           'application_id', r.id, 'candidate_name', r.candidate_name, 'job_title', r.job_title,
           'company_name', r.company_name, 'stage_key', r.stage_key, 'received_at', r.received_at)
         order by r.received_at desc, r.id), '[]'::jsonb) into v_recent
    from (
      select a.id, c.full_name as candidate_name, j.title as job_title, co.name as company_name,
             a.stage_key, a.received_at
        from public.applications a
        join public.candidates c on c.id = a.candidate_id
        join public.jobs j on j.id = a.job_id
        join public.companies co on co.id = a.company_id
       where a.company_id = any (v_visible) and a.in_play
       order by a.received_at desc, a.id
       limit 5
    ) r;

  return jsonb_build_object('by_job', v_by_job, 'not_responding', v_not_responding, 'recent', v_recent);
end $$;

-- --------------------------------------------------------------- opening_counts
-- The Openings panel's per-job counts for the jobs it already loaded: still in
-- play, hired, and everything ever received (the rule for deleting a job).
create or replace function public.opening_counts(p_job_ids uuid[])
returns table (job_id uuid, in_play int, hired int, total int)
language plpgsql stable security definer set search_path = public as $$
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  return query
    select a.job_id,
           (count(*) filter (where a.in_play))::int,
           (count(*) filter (where a.stage_key = 'hired'))::int,
           count(*)::int
      from public.applications a
     where a.job_id = any (coalesce(p_job_ids, '{}'))
       and a.company_id in (select c.id from public.companies c where app.has_capability(c.id, 'candidates.view'))
     group by a.job_id;
end $$;

revoke all on function public.hiring_summary() from public;
revoke all on function public.opening_counts(uuid[]) from public;
grant execute on function public.hiring_summary() to authenticated;
grant execute on function public.opening_counts(uuid[]) to authenticated;

-- ============================================================ Part 2: import
-- (appended by the CSV import task)

commit;
