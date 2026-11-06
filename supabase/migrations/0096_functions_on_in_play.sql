-- 0096_functions_on_in_play.sql
-- Every function on in_play (plan 075). 0095 made rejected and withdrawn
-- what a status *means* (its outcome) instead of stages; this rewrites each
-- function that still reasoned about the stages New, Rejected and Withdrawn:
--
-- * "Is it finished?" reads `applications.in_play` (open outcome, no closure
--   mark), never a list of stages.
-- * A picked status carries its own stage: set_application_status moves the
--   application there, in one event (stage_change when the stage changes,
--   else status_change, or outreach within Screening). A closed application
--   takes no status, and "Hired" is only ever set by confirming the hire.
-- * Closing a job (close_jobs with withdraw, withdraw_in_play, or the hire
--   that fills it) puts the closure mark — closed_at + closed_reason — on the
--   applications still in play and leaves their status alone (the user's
--   decision, 2026-11-05). One helper, app.close_in_play, does it for all
--   three.
-- * The Zoho importers and the old status mappers are dropped; the CSV
--   import (a later migration) replaces them.
--
-- Each function starts from its live definition after 0095; only the stage
-- logic changes. Functions never write in_play: they set the status or
-- closed_at and the t3_sub_status trigger computes it.
--
-- 0018's one-off auto-withdraw (duplicates moved to stage 'withdrawn') was a
-- data fix run once inside that migration, not a function; 0095 rebuilt its
-- unique index on in_play, so nothing live is left of it.

begin;

-- ------------------------------------------------------------- the dropped
-- The Zoho Recruit importers (0058 onwards) and the mappers only they used.
-- server/src/zohoRecruit and scripts/zoho-import.sh still call the two
-- importers until the CSV import replaces them.
drop function public.import_zoho_recruit(jsonb, boolean);
drop function public.import_zoho_history(jsonb, boolean);
drop function app.backfill_sub_statuses();
drop function app.reason_sub_status(text, text);
drop function app.zoho_sub_status(text);

-- ------------------------------------------------------- the closure mark
-- The applications of one job still in play get closed_at and the reason,
-- each with one status_change event (status unchanged, so from = to). The
-- event first, while the row is still in play. Returns how many it marked.
create or replace function app.close_in_play(p_job_id uuid, p_actor uuid, p_reason text) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into public.application_events
    (application_id, actor_id, kind, body, from_stage_key, to_stage_key, from_sub_status_key, to_sub_status_key)
    select a.id, p_actor, 'status_change', p_reason, a.stage_key, a.stage_key, a.sub_status_key, a.sub_status_key
      from public.applications a
     where a.job_id = p_job_id and a.in_play;
  get diagnostics v_n = row_count;
  update public.applications
     set closed_at = now(), closed_reason = p_reason
   where job_id = p_job_id and in_play;
  return v_n;
end $$;

-- ------------------------------------------------------------ fill on hire
-- 0090, plus the closure mark: the hire that fills the job closes the rest
-- with "Position filled." (the user's decision, 2026-11-05).
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
    if found then
      perform app.close_in_play(new.job_id, app.current_person_id(), 'Position filled.');
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------- withdraw_in_play
create or replace function public.withdraw_in_play(p_job_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_reason text := coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Position filled.');
  v_job record;
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
  return jsonb_build_object('withdrawn', app.close_in_play(v_job.id, v_me, v_reason));
end $$;

-- ---------------------------------------------------------------- close_jobs
create or replace function public.close_jobs(p_job_ids uuid[], p_reason text default null, p_withdraw boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_withdraw boolean := coalesce(p_withdraw, false);
  v_id uuid;
  v_job record;
  v_closed int := 0;
  v_already int := 0;
  v_withdrawn int := 0;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if coalesce(array_length(p_job_ids, 1), 0) = 0 then
    raise exception 'Pick at least one job opening.' using errcode = '22023';
  end if;
  if length(coalesce(v_reason, '')) > 2000 then
    raise exception 'Keep the reason to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  if v_withdraw and (v_reason is null or length(v_reason) < 5) then
    raise exception 'Give the reason — it is written onto every application you withdraw.'
      using errcode = '22023';
  end if;

  for v_id in select distinct u.id from unnest(p_job_ids) u(id) loop
    select j.id, j.status, j.company_id, j.title, co.name as company_name
      into v_job
      from public.jobs j
      join public.companies co on co.id = j.company_id
     where j.id = v_id;
    if not found then
      raise exception 'That job opening no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_job.company_id, 'jobs.edit') then
      raise exception 'You need "Edit job descriptions" in % to close %.',
        v_job.company_name, v_job.title using errcode = '42501';
    end if;
    if v_withdraw and not app.has_capability(v_job.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" in % to withdraw the candidates on %.',
        v_job.company_name, v_job.title using errcode = '42501';
    end if;

    if v_job.status = 'closed' then
      v_already := v_already + 1;
    else
      update public.jobs
         set status = 'closed', closed_at = now(), closed_by = v_me, closed_reason = v_reason
       where id = v_job.id;
      v_closed := v_closed + 1;
    end if;

    if v_withdraw then
      v_withdrawn := v_withdrawn + app.close_in_play(v_job.id, v_me, v_reason);
    end if;
  end loop;

  return jsonb_build_object('closed', v_closed, 'already_closed', v_already, 'withdrawn', v_withdrawn);
end $$;

-- ------------------------------------------------------ set_application_status
-- The status names its stage, so picking one moves the application there.
-- rejected_reason / withdrawn_reason follow a status with that outcome the
-- way they followed the old stages: filled in while blank or still the old
-- status's label, never over free text somebody wrote.
create or replace function public.set_application_status(p_application_ids uuid[], p_sub_status_key text, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_key text := nullif(trim(coalesce(p_sub_status_key, '')), '');
  v_note text := trim(coalesce(p_note, ''));
  v_id uuid;
  v_app record;
  v_status record;
  v_n int := 0;
  v_constraint text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if coalesce(array_length(p_application_ids, 1), 0) = 0 then
    raise exception 'Pick at least one application.' using errcode = '22023';
  end if;
  if v_key is null then
    raise exception 'Pick a status.' using errcode = '22023';
  end if;
  if length(v_note) > 2000 then
    raise exception 'Keep the note to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  select s.key, s.label, s.stage_key, s.outcome, s.archived_at into v_status
    from public.application_sub_statuses s
   where s.key = v_key;
  if not found then
    raise exception 'That status no longer exists.' using errcode = '22023';
  end if;
  if v_status.outcome = 'hired' then
    raise exception 'Hire through the offer — "Hired" is set when the offer is accepted.' using errcode = '22023';
  end if;
  if v_status.archived_at is not null then
    raise exception '"%" is retired — pick another status.', v_status.label using errcode = '22023';
  end if;

  for v_id in select distinct u.id from unnest(p_application_ids) u(id) loop
    select a.id, a.company_id, a.stage_key, a.sub_status_key, a.closed_at, a.rejected_reason, a.withdrawn_reason,
           c.full_name, co.name as company_name, os.label as old_label, os.outcome as old_outcome
      into v_app
      from public.applications a
      join public.candidates c on c.id = a.candidate_id
      join public.companies co on co.id = a.company_id
      left join public.application_sub_statuses os on os.key = a.sub_status_key
     where a.id = v_id;
    if not found then
      raise exception 'That application no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_app.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" in % to set a status.', v_app.company_name
        using errcode = '42501';
    end if;
    if v_app.closed_at is not null then
      raise exception 'This job was closed on %. Reopen the job first.', to_char(v_app.closed_at, 'YYYY-MM-DD')
        using errcode = '22023';
    end if;
    -- Any other status would move a hire out of Hired.
    if v_app.old_outcome = 'hired' then
      raise exception '% was hired from this application. It stays on the record.', v_app.full_name
        using errcode = '22023';
    end if;
    insert into public.application_events
      (application_id, actor_id, kind, body, from_stage_key, to_stage_key, from_sub_status_key, to_sub_status_key)
    values (v_app.id, v_me,
            case when v_app.stage_key is distinct from v_status.stage_key then 'stage_change'
                 when v_status.stage_key = 'screening' then 'outreach'
                 else 'status_change' end,
            nullif(v_note, ''), v_app.stage_key, v_status.stage_key, v_app.sub_status_key, v_key);
    begin
      update public.applications
         set stage_key = v_status.stage_key,
             sub_status_key = v_key,
             rejected_reason = case
               when v_status.outcome = 'rejected'
                and (btrim(coalesce(v_app.rejected_reason, '')) = ''
                     or lower(btrim(v_app.rejected_reason)) = lower(btrim(coalesce(v_app.old_label, ''))))
               then v_status.label else rejected_reason end,
             withdrawn_reason = case
               when v_status.outcome = 'withdrew'
                and (btrim(coalesce(v_app.withdrawn_reason, '')) = ''
                     or lower(btrim(v_app.withdrawn_reason)) = lower(btrim(coalesce(v_app.old_label, ''))))
               then v_status.label else withdrawn_reason end
       where id = v_app.id;
    exception when unique_violation then
      -- Back in play from a finished status while a newer one is open.
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'applications_one_open_per_candidate' then
        raise exception '% already has an open application for this job.', v_app.full_name using errcode = '22023';
      end if;
      raise;
    end;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('set', v_n);
end $$;

-- --------------------------------------------------------------- log_outreach
create or replace function public.log_outreach(p_application_ids uuid[], p_sub_status_key text, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_key text := nullif(trim(coalesce(p_sub_status_key, '')), '');
  v_note text := trim(coalesce(p_note, ''));
  v_id uuid;
  v_app record;
  v_n int := 0;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if coalesce(array_length(p_application_ids, 1), 0) = 0 then
    raise exception 'Pick at least one application.' using errcode = '22023';
  end if;
  if v_key is null then
    raise exception 'Pick a sub-status.' using errcode = '22023';
  end if;
  if length(v_note) > 2000 then
    raise exception 'Keep the note to 2,000 characters or fewer.' using errcode = '22023';
  end if;

  -- The same id twice is one application, one event, one count.
  for v_id in select distinct u.id from unnest(p_application_ids) u(id) loop
    select a.id, a.company_id, a.stage_key, a.sub_status_key,
           c.full_name, co.name as company_name, st.label as stage_label
      into v_app
      from public.applications a
      join public.candidates c on c.id = a.candidate_id
      join public.companies co on co.id = a.company_id
      join public.application_stages st on st.key = a.stage_key
     where a.id = v_id;
    if not found then
      raise exception 'That application no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_app.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" in % to log outreach.', v_app.company_name
        using errcode = '42501';
    end if;
    if v_app.stage_key <> 'screening' then
      raise exception '% is at % — outreach is logged at Screening.', v_app.full_name, v_app.stage_label
        using errcode = '22023';
    end if;
    if not exists (select 1 from public.application_sub_statuses s
                    where s.key = v_key and s.stage_key = v_app.stage_key and s.archived_at is null) then
      raise exception '"%" is not a sub-status of the % stage.', v_key, v_app.stage_key
        using errcode = '22023';
    end if;
    insert into public.application_events
      (application_id, actor_id, kind, body, from_sub_status_key, to_sub_status_key)
    values (v_app.id, v_me, 'outreach', nullif(v_note, ''), v_app.sub_status_key, v_key);
    update public.applications set sub_status_key = v_key where id = v_app.id;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('logged', v_n);
end $$;

-- ------------------------------------------------------------- not_responding
-- Screening's contact statuses, still in play on a live job, quiet 30 days.
create or replace function app.not_responding(a public.applications) returns boolean
language sql stable security definer set search_path = public as $$
  select a.sub_status_key is not null
     and a.in_play
     and a.stage_key = 'screening'
     and a.sub_status_key in ('sourced', 'contact_attempted', 'contacted')
     and exists (select 1 from public.jobs j
                  where j.id = a.job_id and j.status in ('ready', 'open', 'on_hold'))
     and coalesce((select max(e.created_at) from public.application_events e
                    where e.application_id = a.id), a.received_at)::date
         < current_date - 30
$$;

-- -------------------------------------------------- notify_application_owner
create or replace function app.notify_application_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_candidate text; v_job text;
begin
  if new.owner_id is null or new.owner_id is not distinct from old.owner_id and new.next_action is not distinct from old.next_action then return new; end if;
  if new.owner_id = app.current_person_id() or not new.in_play then return new; end if;
  select c.full_name, j.title into v_candidate, v_job from public.applications a
    join public.candidates c on c.id = a.candidate_id join public.jobs j on j.id = a.job_id where a.id = new.id;
  perform app.notify(new.owner_id, new.company_id, 'candidate.assigned', 'Candidate assigned to you: ' || coalesce(v_candidate, 'Candidate'),
    coalesce(v_job, 'Role') || ' · ' || coalesce(new.next_action, 'set the next action') || coalesce(' · due ' || to_char(new.next_action_due, 'DD Mon YYYY'), ''),
    '/hiring/applications/' || new.id, 'application', new.id,
    'candidate.assigned:' || new.id || ':' || new.owner_id || ':' || coalesce(new.next_action, ''));
  return new;
end $$;

-- ----------------------------------------------------------- open_application
-- No stage on insert: the column default (screening) and the default status
-- for the source.
create or replace function app.open_application(p_candidate uuid, p_job uuid, p_source_key text, p_override_wait boolean)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_cand record;
  v_job record;
  v_id uuid;
  v_constraint text;
begin
  select id, full_name into v_cand from public.candidates where id = p_candidate for update;
  if not found then
    raise exception 'That candidate no longer exists.' using errcode = '22023';
  end if;
  perform app.assert_contactable(p_candidate, p_override_wait);
  select id, company_id, status into v_job from public.jobs where id = p_job;
  if not found then
    raise exception 'That job no longer exists.' using errcode = '22023';
  end if;
  if v_job.status in ('filled', 'closed') then
    raise exception 'This job is %. Reopen it before adding candidates.', v_job.status;
  end if;
  if p_source_key is null
     or not exists (select 1 from public.candidate_sources where key = p_source_key and archived_at is null) then
    raise exception 'Unknown candidate source "%".', p_source_key using errcode = '22023';
  end if;
  begin
    insert into public.applications (job_id, company_id, candidate_id, source_key)
      values (p_job, v_job.company_id, p_candidate, p_source_key)
      returning id into v_id;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'applications_one_open_per_candidate' then
      raise exception '% already has an open application for this job.', v_cand.full_name;
    end if;
    raise;
  end;
  return v_id;
end $$;

-- -------------------------------------------------- detach_candidate_from_job
-- "Still at New" is now: Screening, on the status a new application starts
-- with (New, or Associated when sourced).
create or replace function public.detach_candidate_from_job(p_application_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_app record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  select a.id, a.company_id, a.stage_key, a.sub_status_key, a.source_key, a.employment_period_id,
         a.source_provider, a.owner_id, a.next_action,
         c.full_name as candidate_name, j.title as job_title, co.name as company_name
    into v_app
    from public.applications a
    join public.candidates c on c.id = a.candidate_id
    join public.jobs j on j.id = a.job_id
    join public.companies co on co.id = a.company_id
   where a.id = p_application_id;
  if not found then
    raise exception 'That application no longer exists.' using errcode = '22023';
  end if;

  if not app.has_capability(v_app.company_id, 'candidates.review') then
    raise exception 'Undoing this needs "Record interview feedback" in %.', v_app.company_name
      using errcode = '42501';
  end if;

  -- An import is not a mistake somebody made here, and re-running it would
  -- put the row straight back.
  if v_app.source_provider is not null then
    raise exception '% came from %, so it is history rather than a mistake. Reject or withdraw it instead.',
      v_app.candidate_name, v_app.source_provider using errcode = '22023';
  end if;
  if v_app.employment_period_id is not null then
    raise exception '% was hired from this application. It stays on the record.', v_app.candidate_name
      using errcode = '22023';
  end if;
  -- An owner was told about this by email (0034's t9_notify) and is carrying
  -- it in their queue. Deleting it under them leaves a notification pointing
  -- at nothing, and no application_events row is written when somebody is
  -- assigned, so nothing else here would have caught it.
  if v_app.owner_id is not null or v_app.next_action is not null then
    raise exception '% is assigned to somebody here. Take the owner off it first, or reject or withdraw it.',
      v_app.candidate_name using errcode = '22023';
  end if;
  if v_app.stage_key <> 'screening'
     or v_app.sub_status_key is distinct from app.default_sub_status('screening', v_app.source_key) then
    raise exception '% has already moved on from New, so this is history now. Reject or withdraw it instead.',
      v_app.candidate_name using errcode = '22023';
  end if;
  if exists (select 1 from public.application_events e where e.application_id = v_app.id) then
    raise exception 'Something has already been recorded against % here. Reject or withdraw it instead.',
      v_app.candidate_name using errcode = '22023';
  end if;
  if exists (select 1 from public.interviews i where i.application_id = v_app.id) then
    raise exception '% has an interview on this job. Reject or withdraw it instead.', v_app.candidate_name
      using errcode = '22023';
  end if;
  if exists (select 1 from public.offers o where o.application_id = v_app.id) then
    raise exception '% has an offer on this job. Reject or withdraw it instead.', v_app.candidate_name
      using errcode = '22023';
  end if;
  if exists (select 1 from public.application_files f where f.application_id = v_app.id) then
    raise exception 'A file was filed against % here. Reject or withdraw it instead, so the file keeps its place.',
      v_app.candidate_name using errcode = '22023';
  end if;

  -- The audit trigger on applications (0005) records the removal with the row
  -- it removed, so an undo is never invisible.
  delete from public.applications where id = v_app.id;

  return jsonb_build_object('detached', true, 'candidate', v_app.candidate_name, 'job', v_app.job_title);
end $$;

-- --------------------------------------------------------- recruitment_report
-- Funnel: the four stages count applications still in play there, except
-- Hired (every hire); rejected and withdrew count by outcome, and closed
-- counts the open ones a closed job marked, so every application lands in
-- exactly one bucket.
create or replace function public.recruitment_report(p_company_id uuid, p_from date, p_to date) returns jsonb
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
                            and a.in_play),
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
  -- currently open; counts are the applications' current stage and outcome.
  select coalesce(jsonb_agg(row_to_json(f)::jsonb order by f.received desc, f.title), '[]'::jsonb) into v_funnel
  from (
    select j.id as job_id, j.title, j.status,
           count(a.id) filter (where a.received_at >= v_from and a.received_at < v_to) as received,
           jsonb_build_object(
             'screening',  count(a.id) filter (where a.in_play and a.stage_key = 'screening'),
             'interview',  count(a.id) filter (where a.in_play and a.stage_key = 'interview'),
             'offer',      count(a.id) filter (where a.in_play and a.stage_key = 'offer'),
             'hired',      count(a.id) filter (where s.outcome = 'hired'),
             'rejected',   count(a.id) filter (where s.outcome = 'rejected'),
             'withdrew',   count(a.id) filter (where s.outcome = 'withdrew'),
             'closed',     count(a.id) filter (where s.outcome = 'open' and a.closed_at is not null)
           ) as stages,
           count(a.id) filter (where s.outcome = 'hired') as hired
    from public.jobs j
    left join public.applications a on a.job_id = j.id
    left join public.application_sub_statuses s on s.key = a.sub_status_key
    where j.company_id = p_company_id
    group by j.id, j.title, j.status
    having j.status = 'open'
        or count(a.id) filter (where a.received_at >= v_from and a.received_at < v_to) > 0
  ) f;

  -- Sources: received in range, reached interview or beyond, hired.
  select coalesce(jsonb_agg(row_to_json(s)::jsonb order by s.received desc, s.source), '[]'::jsonb) into v_sources
  from (
    select coalesce(cs.label, c.label, 'Added by hand') as source,
           count(*) as received,
           count(*) filter (where a.stage_key in ('interview', 'offer', 'hired')
                            or exists (select 1 from public.application_events e
                                       where e.application_id = a.id and e.kind = 'stage_change'
                                         and e.to_stage_key in ('interview', 'offer', 'hired'))) as interviewed,
           count(*) filter (where a.stage_key = 'hired') as hired
    from public.applications a
    left join public.candidate_sources cs on cs.key = a.source_key
    left join public.channels c on c.key = a.source_channel_key
    where a.company_id = p_company_id
      and a.received_at >= v_from and a.received_at < v_to
    group by coalesce(cs.label, c.label, 'Added by hand')
  ) s;

  select jsonb_build_object(
    'overdue_next_actions', (select count(*) from public.applications a
                             where a.company_id = p_company_id
                               and a.in_play
                               and a.next_action_due is not null and a.next_action_due < current_date),
    'unassigned', (select count(*) from public.applications a
                   join public.jobs j on j.id = a.job_id
                   where a.company_id = p_company_id
                     and j.status = 'open'
                     and a.in_play
                     and a.owner_id is null),
    'stale', (select count(*) from public.applications a
              join public.jobs j on j.id = a.job_id
              where a.company_id = p_company_id
                and j.status = 'open'
                and a.in_play
                and coalesce((select max(e.created_at) from public.application_events e
                              where e.application_id = a.id and e.kind = 'stage_change'), a.received_at)
                    < now() - interval '14 days'),
    'not_responding', (select count(*) from public.applications a
                       where a.company_id = p_company_id and app.not_responding(a))
  ) into v_attention;

  return jsonb_build_object(
    'company_id', p_company_id,
    'from', p_from, 'to', p_to,
    'kpis', v_kpis, 'funnel', v_funnel, 'sources', v_sources, 'attention', v_attention
  );
end $$;

-- ------------------------------------------------------ link_hired_application
-- "Hired" is the outcome of the one status of the Hired stage.
create or replace function public.link_hired_application(p_application_id uuid, p_person_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_app record;
  v_person record;
  v_period uuid;
  v_company text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_app from public.applications where id = p_application_id for update;
  if not found then
    raise exception 'That application no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_app.company_id, 'employment.edit') then
    raise exception 'Linking a hire needs the "Edit employment information" capability in this company.'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.application_sub_statuses s
                  where s.key = v_app.sub_status_key and s.outcome = 'hired') then
    raise exception 'Only hired applications can be linked to an employee record.' using errcode = '22023';
  end if;
  if v_app.employment_period_id is not null then
    raise exception 'This application is already linked to an employee record.' using errcode = '22023';
  end if;
  if p_person_id is null then
    update public.applications
      set custom = jsonb_set(custom, '{zoho}', app.jsonb_object_or_empty(custom->'zoho')
            || jsonb_build_object('proposed_person', null, 'link_declined_by', v_me, 'link_declined_at', now()))
      where id = p_application_id;
    return jsonb_build_object('linked', false);
  end if;
  select id, full_name into v_person from public.people where id = p_person_id;
  if not found then
    raise exception 'That person no longer exists.' using errcode = '22023';
  end if;
  select ep.id into v_period from public.employment_periods ep
    where ep.person_id = p_person_id and ep.company_id = v_app.company_id
    order by abs(ep.start_date - coalesce((v_app.custom #>> '{zoho,hired_date}')::date, v_app.received_at::date)),
             ep.start_date desc
    limit 1;
  if v_period is null then
    select name into v_company from public.companies where id = v_app.company_id;
    raise exception '% has no employment record in %.', v_person.full_name, v_company using errcode = '22023';
  end if;
  begin
    update public.applications set employment_period_id = v_period where id = p_application_id;
  exception when unique_violation then
    raise exception 'That employment record is already linked to another application.' using errcode = '22023';
  end;
  insert into public.application_events (application_id, kind, body, actor_id)
    values (p_application_id, 'note',
            format('Linked to the employee record of %s by %s.', v_person.full_name, app.person_name(v_me)), v_me);
  return jsonb_build_object('linked', true, 'employment_period_id', v_period, 'person_id', p_person_id);
end $$;

-- ---------------------------------------------------------- remove_sub_status
-- The moved applications' event kind and reason columns follow the stage and
-- the outcome of the status they move to.
create or replace function public.remove_sub_status(p_key text, p_move_to text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_from record;
  v_to_key text;
  v_to_label text;
  v_to_outcome text;
  v_move text := nullif(trim(coalesce(p_move_to, '')), '');
  v_n int := 0;
  v_outcome text;
begin
  if not app.is_admin() then
    raise exception 'Only platform admins manage hiring statuses.' using errcode = '42501';
  end if;
  select s.key, s.stage_key, s.label, s.archived_at into v_from
    from public.application_sub_statuses s where s.key = p_key
     for update;
  if not found then
    raise exception 'That status no longer exists.' using errcode = '22023';
  end if;
  if v_from.key in ('applied', 'sourced', 'contact_attempted', 'contacted') then
    raise exception '"%" is used by the pipeline''s own rules — rename it instead.', v_from.label
      using errcode = '22023';
  end if;

  if v_move is not null then
    select s.key, s.label, s.outcome into v_to_key, v_to_label, v_to_outcome
      from public.application_sub_statuses s
     where s.key = v_move and s.stage_key = v_from.stage_key and s.archived_at is null and s.key <> v_from.key;
    if not found then
      raise exception 'Pick another live status of the same stage to move its applications to.'
        using errcode = '22023';
    end if;
    alter table public.applications disable trigger audit;
    alter table public.application_events disable trigger t8_touch_candidate;
    insert into public.application_events
      (application_id, actor_id, kind, body, from_sub_status_key, to_sub_status_key)
      select a.id, v_me,
             case when a.stage_key = 'screening' then 'outreach' else 'status_change' end,
             format('Status "%s" removed.', v_from.label), v_from.key, v_to_key
        from public.applications a
       where a.sub_status_key = v_from.key;
    get diagnostics v_n = row_count;
    update public.applications a
       set sub_status_key = v_to_key,
           rejected_reason = case
             when v_to_outcome = 'rejected'
              and (btrim(coalesce(a.rejected_reason, '')) = '' or lower(btrim(a.rejected_reason)) = lower(btrim(v_from.label)))
             then v_to_label else a.rejected_reason end,
           withdrawn_reason = case
             when v_to_outcome = 'withdrew'
              and (btrim(coalesce(a.withdrawn_reason, '')) = '' or lower(btrim(a.withdrawn_reason)) = lower(btrim(v_from.label)))
             then v_to_label else a.withdrawn_reason end
     where a.sub_status_key = v_from.key;
    alter table public.application_events enable trigger t8_touch_candidate;
    alter table public.applications enable trigger audit;
  end if;

  if not exists (select 1 from public.applications where sub_status_key = v_from.key)
     and not exists (select 1 from public.application_events
                      where from_sub_status_key = v_from.key or to_sub_status_key = v_from.key) then
    delete from public.application_sub_statuses where key = v_from.key;
    v_outcome := 'deleted';
  else
    update public.application_sub_statuses set archived_at = coalesce(archived_at, now()) where key = v_from.key;
    v_outcome := 'retired';
  end if;

  insert into public.activity_log (actor_person_id, actor_user_id, entity_type, entity_id, action, before, after)
  values (v_me, auth.uid(), 'application_sub_statuses', v_from.key,
          case v_outcome when 'deleted' then 'DELETE' else 'UPDATE' end,
          jsonb_build_object('key', v_from.key, 'stage_key', v_from.stage_key, 'label', v_from.label,
                             'archived_at', v_from.archived_at),
          jsonb_build_object('outcome', v_outcome, 'moved', v_n, 'moved_to', v_to_key, 'moved_to_label', v_to_label));

  return jsonb_build_object('moved', v_n, 'outcome', v_outcome);
end $$;

-- ------------------------------------------------------------ create_employee
-- 0039, with "at the offer stage" meaning still in play there (a declined,
-- withdrawn or closed offer used to leave the Offer stage).
create or replace function public.create_employee(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_app record;
  v_job record;
  v_candidate record;
  v_application uuid;
  v_company uuid;
  v_name text;
  v_preferred text;
  v_work_email text;
  v_personal_email text;
  v_phone text;
  v_title text;
  v_start date;
  v_type text;
  v_dept uuid;
  v_loc uuid;
  v_manager uuid;
  v_private jsonb := p -> 'private';
  v_pay jsonb := p -> 'pay';
  v_private_given boolean;
  v_pay_given boolean;
  v_start_plan boolean;
  v_person uuid;
  v_period uuid;
  v_plan uuid;
  v_comp uuid;
  v_status text;
  v_problems text[];
  v_contacts jsonb := '[]'::jsonb;
  v_bank jsonb;
  v_address jsonb;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Send the employee as an object.' using errcode = '22023';
  end if;

  v_name := btrim(coalesce(p ->> 'full_name', ''));
  v_preferred := nullif(btrim(coalesce(p ->> 'preferred_name', '')), '');
  v_work_email := lower(nullif(btrim(coalesce(p ->> 'work_email', '')), ''));
  v_personal_email := lower(nullif(btrim(coalesce(p ->> 'personal_email', '')), ''));
  v_phone := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_title := btrim(coalesce(p ->> 'job_title', ''));
  v_type := nullif(btrim(coalesce(p ->> 'employment_type_key', '')), '');
  v_dept := nullif(p ->> 'department_id', '')::uuid;
  v_loc := nullif(p ->> 'location_id', '')::uuid;
  v_manager := nullif(p ->> 'manager_id', '')::uuid;
  v_application := nullif(p ->> 'application_id', '')::uuid;
  v_private_given := app.jsonb_has_values(v_private);
  v_pay_given := v_pay is not null and jsonb_typeof(v_pay) = 'object'
                 and nullif(btrim(coalesce(v_pay ->> 'amount', '')), '') is not null;

  -- Where the employment lands, and whether the caller may put it there.
  if v_application is not null then
    select * into v_app from public.applications where id = v_application for update;
    if not found then
      raise exception 'Application not found.' using errcode = 'P0002';
    end if;
    select * into v_job from public.jobs where id = v_app.job_id;
    v_company := v_job.company_id;
    if not app.has_capability(v_company, 'employment.edit') then
      raise exception 'Confirming a hire requires employment.edit in this company.'
        using errcode = '42501';
    end if;
    if v_app.employment_period_id is not null then
      select person_id into v_person from public.employment_periods
        where id = v_app.employment_period_id;
      select id into v_plan from public.plans
        where employment_period_id = v_app.employment_period_id and kind = 'onboarding'
        limit 1;
      return jsonb_build_object(
        'person_id', v_person,
        'employment_period_id', v_app.employment_period_id,
        'plan_id', v_plan,
        'compensation_record_id', null,
        'already_hired', true);
    end if;
    if v_app.stage_key <> 'offer' or not v_app.in_play then
      raise exception 'Only applications at the offer stage can be confirmed as hires.';
    end if;
    select * into v_candidate from public.candidates where id = v_app.candidate_id;
    -- A hire always gets its checklist (blueprint §8), whatever the date.
    v_start_plan := true;
  else
    v_company := nullif(p ->> 'company_id', '')::uuid;
    if v_company is null then
      raise exception 'Choose the employing company.' using errcode = '22023';
    end if;
    if not app.has_capability(v_company, 'employment.edit') then
      raise exception 'Adding an employee requires employment.edit in this company.'
        using errcode = '42501';
    end if;
    v_start_plan := coalesce((p ->> 'start_onboarding')::boolean, true);
  end if;
  if not exists (select 1 from public.companies where id = v_company and archived_at is null) then
    raise exception 'That company is archived.' using errcode = '22023';
  end if;

  -- The sensitive parts are refused before anything is written.
  if v_private_given and not app.has_capability(v_company, 'personal.view') then
    raise exception 'Personal details need personal.view in this company.'
      using errcode = '42501';
  end if;
  if v_pay_given and not app.has_capability(v_company, 'salary.propose') then
    raise exception 'Proposing compensation requires salary.propose in this company.'
      using errcode = '42501';
  end if;

  -- Identity first, so the shape check can see the person for the manager loop.
  -- A hire attaches to the person the candidate's email already belongs to
  -- only when they hold no open employment — a rehire; a shared address never
  -- merges a new hire into a colleague's record.
  if v_application is not null then
    select p2.id into v_person from public.people p2
      where v_candidate.email is not null
        and (p2.work_email = v_candidate.email or p2.personal_email = v_candidate.email)
        and not exists (
          select 1 from public.employment_periods ep
          join public.employment_statuses es on es.key = ep.status
          where ep.person_id = p2.id and es.counts_as_employed)
      order by p2.created_at
      limit 1;
    -- The address they applied from stays personal unless the caller says otherwise.
    if v_work_email is null and v_personal_email is null and v_candidate.email is not null then
      v_personal_email := lower(v_candidate.email::text);
    end if;
  end if;

  v_problems := app.check_employee(p || jsonb_build_object('person_id', v_person), v_company);
  if cardinality(v_problems) > 0 then
    raise exception '%', v_problems[1] using errcode = '22023';
  end if;
  v_start := (p ->> 'start_date')::date;

  if v_person is null then
    begin
      insert into public.people (full_name, preferred_name, work_email, personal_email, phone)
        values (v_name, v_preferred, v_work_email, v_personal_email, v_phone)
        returning id into v_person;
    exception when unique_violation then
      raise exception 'A person with this work email already exists — open their record and add the employment there.'
        using errcode = '23505';
    end;
  else
    begin
      update public.people
         set preferred_name = coalesce(v_preferred, preferred_name),
             work_email = coalesce(v_work_email, work_email),
             personal_email = coalesce(v_personal_email, personal_email),
             phone = coalesce(v_phone, phone)
       where id = v_person;
    exception when unique_violation then
      raise exception 'Another person already has that work email.' using errcode = '23505';
    end;
  end if;

  v_status := case when v_start > current_date then 'pre_start' else 'active' end;
  begin
    insert into public.employment_periods
        (person_id, company_id, job_title, department_id, location_id,
         employment_type_key, manager_id, status, start_date)
      values (v_person, v_company, v_title, v_dept, v_loc, v_type, v_manager, v_status, v_start)
      returning id into v_period;
  exception when exclusion_violation then
    raise exception 'This person already has an employment period covering that date — end it first.'
      using errcode = '23P01';
  end;

  if v_application is not null then
    update public.applications
      set employment_period_id = v_period, stage_key = 'hired'
      where id = v_application;
    insert into public.application_events
        (application_id, kind, from_stage_key, to_stage_key, actor_id, body)
      values (v_application, 'stage_change', v_app.stage_key, 'hired', v_me, 'Hire confirmed');
  end if;

  if v_private_given then
    if nullif(btrim(coalesce(v_private ->> 'emergency_name', '')), '') is not null
       or nullif(btrim(coalesce(v_private ->> 'emergency_phone', '')), '') is not null then
      v_contacts := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'name', nullif(btrim(coalesce(v_private ->> 'emergency_name', '')), ''),
        'relationship', nullif(btrim(coalesce(v_private ->> 'emergency_relationship', '')), ''),
        'phone', nullif(btrim(coalesce(v_private ->> 'emergency_phone', '')), ''))));
    end if;
    if nullif(btrim(coalesce(v_private ->> 'bank_name', '')), '') is not null
       or nullif(btrim(coalesce(v_private ->> 'bank_account_number', '')), '') is not null then
      v_bank := jsonb_strip_nulls(jsonb_build_object(
        'bank', nullif(btrim(coalesce(v_private ->> 'bank_name', '')), ''),
        'account_number', nullif(btrim(coalesce(v_private ->> 'bank_account_number', '')), '')));
    end if;
    if nullif(btrim(coalesce(v_private ->> 'address_line', '')), '') is not null then
      v_address := jsonb_build_object('line', btrim(v_private ->> 'address_line'));
    end if;
    insert into public.person_private_details
        (person_id, birth_date, address, national_id, bank_account, emergency_contacts, notes)
      values (v_person, nullif(v_private ->> 'birth_date', '')::date, v_address,
              nullif(btrim(coalesce(v_private ->> 'national_id', '')), ''),
              v_bank, v_contacts,
              nullif(btrim(coalesce(v_private ->> 'notes', '')), ''))
      on conflict (person_id) do update set
        birth_date = coalesce(excluded.birth_date, person_private_details.birth_date),
        address = coalesce(excluded.address, person_private_details.address),
        national_id = coalesce(excluded.national_id, person_private_details.national_id),
        bank_account = coalesce(excluded.bank_account, person_private_details.bank_account),
        emergency_contacts = case when excluded.emergency_contacts <> '[]'::jsonb
                                  then excluded.emergency_contacts
                                  else person_private_details.emergency_contacts end,
        notes = coalesce(excluded.notes, person_private_details.notes);
  end if;

  if v_pay_given then
    v_comp := (public.propose_compensation(
      v_period, (v_pay ->> 'amount')::numeric, v_pay ->> 'currency', lower(btrim(v_pay ->> 'pay_basis_key')), v_start,
      v_pay ->> 'note') ->> 'record_id')::uuid;
  end if;

  if v_start_plan then
    v_plan := app.start_onboarding_plan(v_person, v_company, v_period, v_start);
  end if;

  return jsonb_build_object(
    'person_id', v_person,
    'employment_period_id', v_period,
    'plan_id', v_plan,
    'compensation_record_id', v_comp,
    'already_hired', false);
end $$;

-- ---------------------------------------------------------------- grants
-- create or replace keeps each function's grants; only the new helper needs
-- closing off.
revoke all on function app.close_in_play(uuid, uuid, text) from public;

commit;
