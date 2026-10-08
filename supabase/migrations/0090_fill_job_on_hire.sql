-- 0090_fill_job_on_hire.sql
-- A job fills itself (plan 070). HR's note: "when we are closing job, by
-- someone hired it should automatically be closed". The hire that meets a
-- job's headcount moves it to `filled` — the status that already means
-- "closed because we hired", which the reports keep apart from `closed`
-- (abandoned). Nothing else happens to the job's other candidates: they are
-- left where they are, and withdraw_in_play is the one-click way to clear
-- them when HR is ready (the maintainer's choice, 2026-10-08).
--
-- Headcount: the hiring request's, else the number Zoho Recruit kept on the
-- job (`custom->'zoho'->>'headcount'`; all 75 live jobs are Zoho's and none
-- has a request, and ten want two to five hires), else one.
--
-- Only a hire made in PeopleOS fills a job: the trigger fires on a stage
-- moving *to* hired, never on an imported row inserted there, and only for a
-- job still ready, open or on hold. Jobs whose headcount was already met
-- before this migration are left as they are (maintainer: future hires only).

begin;

-- -------------------------------------------------------------- headcount
create or replace function app.job_headcount(p_job_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select greatest(1, coalesce(
    r.headcount,
    case when (j.custom->'zoho'->>'headcount') ~ '^[0-9]{1,4}$'
         then nullif((j.custom->'zoho'->>'headcount')::int, 0) end,
    1))
    from public.jobs j
    left join public.hiring_requests r on r.id = j.hiring_request_id
   where j.id = p_job_id
$$;

-- ------------------------------------------------------------ fill on hire
-- After the stage write, so the hire being made counts. The update to the
-- job goes through its own triggers (audit, touch, closing stamp) like any
-- status change, attributed to whoever confirmed the hire.
create or replace function app.applications_fill_job() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage_key = 'hired' and old.stage_key is distinct from 'hired' then
    update public.jobs j
       set status = 'filled'
     where j.id = new.job_id
       and j.status in ('ready', 'open', 'on_hold')
       and (select count(*) from public.applications a
             where a.job_id = new.job_id and a.stage_key = 'hired') >= app.job_headcount(new.job_id);
  end if;
  return new;
end $$;
create trigger t7_fill_job after update of stage_key on public.applications
  for each row execute function app.applications_fill_job();

-- ------------------------------------------------------ withdraw the rest
-- Everyone still in play on one job — New to Offer — withdrawn at once, as
-- close_jobs (0071/0088) withdraws them: a stage_change event carrying the
-- stage each really left, the reason on the row, "Job closed" as the status
-- while it is live. It leaves the job's own status alone (a filled job stays
-- filled). `candidates.review` in the job's company, like any withdrawal.
create or replace function public.withdraw_in_play(p_job_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_reason text := coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Position filled.');
  v_job record;
  v_n int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if length(v_reason) > 2000 then
    raise exception 'Keep the reason to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  select j.id, j.company_id, j.title, co.name as company_name into v_job
    from public.jobs j join public.companies co on co.id = j.company_id
   where j.id = p_job_id;
  if not found then
    raise exception 'That job opening no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_job.company_id, 'candidates.review') then
    raise exception 'You need "Record interview feedback" in % to withdraw the candidates on %.',
      v_job.company_name, v_job.title using errcode = '42501';
  end if;
  insert into public.application_events (application_id, actor_id, kind, body, from_stage_key, to_stage_key)
    select a.id, v_me, 'stage_change', v_reason, a.stage_key, 'withdrawn'
      from public.applications a
     where a.job_id = v_job.id and a.stage_key not in ('hired', 'rejected', 'withdrawn');
  get diagnostics v_n = row_count;
  update public.applications
     set stage_key = 'withdrawn', withdrawn_reason = v_reason,
         sub_status_key = (select s.key from public.application_sub_statuses s
                            where s.key = 'job_closed' and s.stage_key = 'withdrawn' and s.archived_at is null)
   where job_id = v_job.id and stage_key not in ('hired', 'rejected', 'withdrawn');
  return jsonb_build_object('withdrawn', v_n);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function app.job_headcount(uuid), app.applications_fill_job() from public;
revoke all on function public.withdraw_in_play(uuid, text) from public, anon;
grant execute on function public.withdraw_in_play(uuid, text) to authenticated;

commit;
