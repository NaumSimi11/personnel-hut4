-- 0088_statuses_on_every_stage.sql
-- Statuses on every stage (plan 068). 0069 gave New and Screening a
-- sub-status and kept the other five stages bare: "the other stages are
-- already an answer". HR answered otherwise — she wants her own statuses on
-- every stage, to add one from the Labels page and use it the same day, and
-- to tidy the old closed applications with them.
--
-- The lookup already allows it: `application_sub_statuses.stage_key` points
-- at any stage and `admin_write` lets an admin insert. What held the line was
-- the seed (New and Screening only), `log_outreach` (refuses every other
-- stage) and the app. So this adds a vocabulary for the other five stages,
-- built from what the ~3,300 imported applications already carry — the
-- withdrawal and rejection reasons, and Zoho's own interview, offer and hire
-- statuses — fills those applications in, and opens one door that sets a
-- status at any stage.
--
-- Order: event kind → one label per stage → seed → Zoho map → reason map →
-- defaults → trigger → backfill → set_application_status → close_jobs →
-- grants. One transaction: a half-seeded vocabulary is worse than none.

begin;

-- ------------------------------------------------------------ event kind
-- A status change outside New and Screening is not outreach; the timeline
-- names it for what it is.
alter table public.application_events drop constraint application_events_kind_check;
alter table public.application_events add constraint application_events_kind_check
  check (kind in ('stage_change', 'note', 'interview_feedback', 'outreach', 'status_change'));

-- ------------------------------------------------------- one label each
-- Two live statuses of one stage with the same name would be one choice
-- shown twice — case and surrounding space included, as the reason map
-- reads them. A retired one may share a name with its replacement.
create unique index application_sub_statuses_label_per_stage
  on public.application_sub_statuses (stage_key, lower(btrim(label)))
  where archived_at is null;

-- ------------------------------------------------------------------ seed
-- Rejected and Withdrawn: the reasons already on the applications, word for
-- word, so the backfill can match them. Interview, Offer and Hired: Zoho
-- Recruit's statuses, the words HR used for years, lightly cleaned.
-- `on conflict do nothing`: a key an admin already chose is theirs.
insert into public.application_sub_statuses (key, stage_key, label, sort_order) values
  ('interview_to_schedule',       'interview', 'To be scheduled',                          10),
  ('interview_scheduled',         'interview', 'Scheduled',                                20),
  ('interview_in_progress',       'interview', 'In progress',                              30),
  ('interview_hr',                'interview', 'Interview 1 – HR',                         40),
  ('interview_stakeholders',      'interview', 'Interview 2 – Stakeholders',               50),
  ('interview_other_stakeholder', 'interview', 'Interview 3 – Other stakeholder',          60),
  ('interview_other_stakeholders','interview', 'Interview 4 – Other stakeholders',         70),
  ('interview_feedback_due',      'interview', 'Feedback to be provided',                  80),
  ('submitted_to_manager',        'interview', 'Submitted to the hiring manager',          90),
  ('approved_by_manager',         'interview', 'Approved by the hiring manager',          100),
  ('interview_task',              'interview', 'Task',                                    110),
  ('interview_on_hold',           'interview', 'On hold',                                 120),
  ('no_show',                     'interview', 'No-show',                                 130),
  ('to_be_offered',               'offer',     'To be offered',                            10),
  ('offer_made',                  'offer',     'Offer made',                               20),
  ('offer_accepted',              'hired',     'Offer accepted',                           10),
  ('converted_employee',          'hired',     'Converted – employee',                     20),
  ('converted_temp',              'hired',     'Converted – temp',                         30),
  ('rejected_general',            'rejected',  'Rejected',                                 10),
  ('rejected_by_manager',         'rejected',  'Rejected by the hiring manager',           20),
  ('rejected_by_hr',              'rejected',  'Rejected by HR',                           30),
  ('rejected_after_interview',    'rejected',  'Rejected by the manager after interview',  40),
  ('rejected_for_interview',      'rejected',  'Rejected for interview',                   50),
  ('unqualified',                 'rejected',  'Unqualified',                              60),
  ('rejected_hirable',            'rejected',  'Rejected, hirable later',                  70),
  ('offer_withdrawn',             'rejected',  'Offer withdrawn',                          80),
  ('not_interested',              'withdrawn', 'Not interested',                           10),
  ('no_response',                 'withdrawn', 'No response',                              20),
  ('candidate_withdrew',          'withdrawn', 'Candidate withdrew',                       30),
  ('offer_declined',              'withdrawn', 'Offer declined',                           40),
  ('contact_in_future',           'withdrawn', 'Contact in future',                        50),
  ('do_not_contact',              'withdrawn', 'Do not contact',                           60),
  ('job_closed',                  'withdrawn', 'Job closed',                               70)
on conflict (key) do nothing;

-- ----------------------------------------------------------- zoho status
-- 0069's mapping, extended to every status `STATUS_TO_STAGE`
-- (server/src/zohoRecruit/mapping.ts) names. Still one place, still null
-- for a word we do not map; the backfill's stage guard decides whether the
-- key fits the row.
create or replace function app.zoho_sub_status(p_status text) returns text
language sql immutable security definer set search_path = public as $$
  select case coalesce(p_status, '')
    when 'Associated'                                then 'sourced'
    when 'New'                                       then 'sourced'
    when 'Attempted to Contact'                      then 'contact_attempted'
    when 'Not Contacted'                             then 'contact_attempted'
    when 'Not contacted'                             then 'contact_attempted'
    when 'Contacted'                                 then 'contacted'
    when 'Interested'                                then 'interested'
    when 'Waiting-for-Evaluation'                    then 'awaiting_evaluation'
    when 'Qualified'                                 then 'qualified'
    when 'Interview-to-be-Scheduled'                 then 'interview_to_schedule'
    when 'Interview-Scheduled'                       then 'interview_scheduled'
    when 'Interview-in-Progress'                     then 'interview_in_progress'
    when 'Interview 1 - HR'                          then 'interview_hr'
    when 'Interview 2 - Stakeholders'                then 'interview_stakeholders'
    when 'Interview 3 - Other stakeholder'           then 'interview_other_stakeholder'
    when 'Interview 4 - Other stakeholders'          then 'interview_other_stakeholders'
    when 'Feedback to be provided from an Interview' then 'interview_feedback_due'
    when 'Submitted-to-hiring manager'               then 'submitted_to_manager'
    when 'Approved by hiring manager'                then 'approved_by_manager'
    when 'Task'                                      then 'interview_task'
    when 'On-Hold'                                   then 'interview_on_hold'
    when 'No-Show'                                   then 'no_show'
    when 'To-be-Offered'                             then 'to_be_offered'
    when 'Offer-Made'                                then 'offer_made'
    when 'Offer-Accepted'                            then 'offer_accepted'
    when 'Converted - Employee'                      then 'converted_employee'
    when 'Converted - Temp'                          then 'converted_temp'
    when 'Rejected'                                  then 'rejected_general'
    when 'Rejected by hiring manager'                then 'rejected_by_manager'
    when 'Rejected by HR'                            then 'rejected_by_hr'
    when 'Rejected by Manager - Interview'           then 'rejected_after_interview'
    when 'Rejected-for-Interview'                    then 'rejected_for_interview'
    when 'Unqualified'                               then 'unqualified'
    when 'Rejected-Hirable'                          then 'rejected_hirable'
    when 'Offer-Withdrawn'                           then 'offer_withdrawn'
    when 'Not Interested'                            then 'not_interested'
    when 'Not responding'                            then 'no_response'
    when 'Withdraw Application'                      then 'candidate_withdrew'
    when 'Offer-Declined'                            then 'offer_declined'
    when 'Contact in Future'                         then 'contact_in_future'
    when 'NEVER to be contacted again'               then 'do_not_contact'
    else null
  end
$$;

-- ----------------------------------------------------------- reason map
-- A Rejected or Withdrawn row says why in its reason, whoever closed it —
-- the Zoho import (the reason strings of `STATUS_TO_STAGE` in
-- server/src/zohoRecruit/mapping.ts) or its stale rule ("Job closed"). A
-- fixed map, not a match on `label`: HR renames labels, and a backfill run
-- after the next import must still find these. Case and surrounding space
-- are ignored; null for any other sentence, or when the status is retired
-- or belongs to another stage.
create or replace function app.reason_sub_status(p_stage text, p_reason text) returns text
language sql stable security definer set search_path = public as $$
  select s.key from public.application_sub_statuses s
   where s.stage_key = p_stage and s.archived_at is null
     and s.key = case lower(btrim(coalesce(p_reason, '')))
       when 'rejected'                                then 'rejected_general'
       when 'rejected by the hiring manager'          then 'rejected_by_manager'
       when 'rejected by hr'                          then 'rejected_by_hr'
       when 'rejected by the manager after interview' then 'rejected_after_interview'
       when 'rejected for interview'                  then 'rejected_for_interview'
       when 'unqualified'                             then 'unqualified'
       when 'rejected, hirable later'                 then 'rejected_hirable'
       when 'offer withdrawn'                         then 'offer_withdrawn'
       when 'not interested'                          then 'not_interested'
       when 'no response'                             then 'no_response'
       when 'candidate withdrew'                      then 'candidate_withdrew'
       when 'offer declined'                          then 'offer_declined'
       when 'contact in future'                       then 'contact_in_future'
       when 'do not contact'                          then 'do_not_contact'
       when 'job closed'                              then 'job_closed'
     end
$$;

-- -------------------------------------------------------- the rule keys
-- Four statuses are named by the rules themselves: New's two defaults
-- (`applied`, `sourced`, chosen by source below) and the three "not
-- responding" counts (`sourced`, `contact_attempted`, `contacted` —
-- app.not_responding, 0069). Retiring one would quietly change those rules —
-- every careers-site applicant landing at Sourced, and 30 days later counted
-- as not responding — so they can be renamed but not retired.
alter table public.application_sub_statuses add constraint application_sub_statuses_rule_keys_stay
  check (archived_at is null or key not in ('applied', 'sourced', 'contact_attempted', 'contacted'));

-- --------------------------------------------------------------- default
-- New and Screening still always carry a status; the other five start
-- blank, because an application that reaches Interview has not yet been
-- scheduled, offered or anything else — somebody says which. New's two
-- defaults cannot be retired (above); Screening's is its first live one.
create or replace function app.default_sub_status(p_stage text, p_source_key text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_stage = 'new' then
      case when coalesce(p_source_key, '') in ('head_hunt', 'linkedin_profile', 'imported')
           then 'sourced' else 'applied' end
    when p_stage = 'screening' then
      (select s.key from public.application_sub_statuses s
        where s.stage_key = 'screening' and s.archived_at is null
        order by s.sort_order, s.key limit 1)
    else null
  end
$$;

-- --------------------------------------------------------------- trigger
-- 0069's guard, with one sentence of its own for a retired status: "is not
-- a sub-status of the stage" is untrue of a status that was one yesterday.
create or replace function app.applications_sub_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_label text;
begin
  if tg_op = 'INSERT' then
    if new.sub_status_key is null
       or not exists (select 1 from public.application_sub_statuses s
                       where s.key = new.sub_status_key
                         and s.stage_key = new.stage_key
                         and s.archived_at is null) then
      new.sub_status_key := app.default_sub_status(new.stage_key, new.source_key);
    end if;
    return new;
  end if;
  if new.stage_key is not distinct from old.stage_key
     and new.sub_status_key is not distinct from old.sub_status_key then
    return new;
  end if;
  if new.sub_status_key is not null
     and exists (select 1 from public.application_sub_statuses s
                  where s.key = new.sub_status_key
                    and s.stage_key = new.stage_key
                    and s.archived_at is null) then
    return new;
  end if;
  if new.stage_key is distinct from old.stage_key or new.sub_status_key is null then
    new.sub_status_key := app.default_sub_status(new.stage_key, new.source_key);
    return new;
  end if;
  select s.label into v_label from public.application_sub_statuses s
   where s.key = new.sub_status_key and s.stage_key = new.stage_key and s.archived_at is not null;
  if found then
    raise exception '"%" is retired — pick another status.', v_label using errcode = '22023';
  end if;
  raise exception '"%" is not a sub-status of the % stage.', new.sub_status_key, new.stage_key
    using errcode = '22023';
end $$;

-- -------------------------------------------------------------- backfill
-- Rejected and Withdrawn by their reason first (it is what the app shows),
-- then by the Zoho status; Interview, Offer and Hired by the Zoho status.
-- A candidate withdrawn by close_jobs before this migration carries the
-- sentence the closer typed, which is also the job's closed_reason: that is
-- "Job closed", as every close from now on records it. The join to the
-- lookup is the stage guard, as in 0069. A row that already carries a
-- status keeps it, and a row nothing maps is not touched, so the count is
-- what was labelled and a second run labels only what is new — the Zoho
-- import inserts without one, and scripts/zoho-import.sh runs this after
-- it. The audit and timestamp triggers stay off for the sweep (the 0086
-- discipline): this is history being labelled, not somebody's edit, and
-- `updated_at` is what the application page's optimistic lock compares.
create or replace function app.backfill_sub_statuses() returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  alter table public.applications disable trigger touch;
  alter table public.applications disable trigger audit;
  update public.applications a
     set sub_status_key = m.key
    from (
      select x.id, coalesce(
        case x.stage_key
          when 'rejected'  then app.reason_sub_status('rejected', x.rejected_reason)
          when 'withdrawn' then app.reason_sub_status('withdrawn', x.withdrawn_reason)
        end,
        (select s.key from public.application_sub_statuses s
          where s.stage_key = x.stage_key and s.archived_at is null
            and s.key = app.zoho_sub_status(x.custom->'zoho'->>'status')),
        case when x.stage_key = 'withdrawn'
              and exists (select 1 from public.jobs j
                           where j.id = x.job_id and j.status = 'closed'
                             and j.closed_reason is not null and j.closed_reason = x.withdrawn_reason)
             then app.reason_sub_status('withdrawn', 'Job closed') end
      ) as key
        from public.applications x
       where x.stage_key in ('interview', 'offer', 'hired', 'rejected', 'withdrawn')
         and x.sub_status_key is null
    ) m
   where a.id = m.id and m.key is not null;
  get diagnostics v_n = row_count;
  alter table public.applications enable trigger touch;
  alter table public.applications enable trigger audit;
  return v_n;
end $$;
select app.backfill_sub_statuses();

-- ------------------------------------------------------------------- RPC
-- 0069's log_outreach without the stage line: one door for one row and for
-- fifty, at any stage, all or nothing. At New and Screening the event is
-- still `outreach` — the "not responding" rule and the timeline read it so;
-- elsewhere it is a `status_change`. Closed applications are allowed on
-- purpose: tidying the old ones is half of why this exists. On a Rejected or
-- Withdrawn row the stored reason follows the status when it was only the
-- old status's name (or nothing), so the page never reads "Rejected: Rejected
-- by HR" beside "Unqualified"; a reason somebody wrote in their own words
-- stays. log_outreach stays as it was for the build already deployed.
create or replace function public.set_application_status(
  p_application_ids uuid[],
  p_sub_status_key text,
  p_note text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_key text := nullif(trim(coalesce(p_sub_status_key, '')), '');
  v_note text := trim(coalesce(p_note, ''));
  v_id uuid;
  v_app record;
  v_status record;
  v_n int := 0;
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
  for v_id in select distinct u.id from unnest(p_application_ids) u(id) loop
    select a.id, a.company_id, a.stage_key, a.sub_status_key, a.rejected_reason, a.withdrawn_reason,
           c.full_name, co.name as company_name, st.label as stage_label, os.label as old_label
      into v_app
      from public.applications a
      join public.candidates c on c.id = a.candidate_id
      join public.companies co on co.id = a.company_id
      join public.application_stages st on st.key = a.stage_key
      left join public.application_sub_statuses os on os.key = a.sub_status_key
     where a.id = v_id;
    if not found then
      raise exception 'That application no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_app.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" in % to set a status.', v_app.company_name
        using errcode = '42501';
    end if;
    select s.label, s.archived_at into v_status
      from public.application_sub_statuses s
     where s.key = v_key and s.stage_key = v_app.stage_key;
    if not found then
      raise exception '"%" is not a status of the % stage, where % is.', v_key, v_app.stage_label, v_app.full_name
        using errcode = '22023';
    end if;
    if v_status.archived_at is not null then
      raise exception '"%" is retired — pick another status.', v_status.label using errcode = '22023';
    end if;
    insert into public.application_events
      (application_id, actor_id, kind, body, from_sub_status_key, to_sub_status_key)
    values (v_app.id, v_me,
            case when v_app.stage_key in ('new', 'screening') then 'outreach' else 'status_change' end,
            nullif(v_note, ''), v_app.sub_status_key, v_key);
    update public.applications
       set sub_status_key = v_key,
           rejected_reason = case
             when v_app.stage_key = 'rejected'
              and (btrim(coalesce(v_app.rejected_reason, '')) = ''
                   or lower(btrim(v_app.rejected_reason)) = lower(btrim(coalesce(v_app.old_label, ''))))
             then v_status.label else rejected_reason end,
           withdrawn_reason = case
             when v_app.stage_key = 'withdrawn'
              and (btrim(coalesce(v_app.withdrawn_reason, '')) = ''
                   or lower(btrim(v_app.withdrawn_reason)) = lower(btrim(coalesce(v_app.old_label, ''))))
             then v_status.label else withdrawn_reason end
     where id = v_app.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('set', v_n);
end $$;

-- ------------------------------------------------------------ close_jobs
-- 0071's function with one line added: a candidate withdrawn because the
-- job closed is at "Job closed", while that status is live. The typed
-- reason still goes onto the row as before.
create or replace function public.close_jobs(
  p_job_ids uuid[],
  p_reason text default null,
  p_withdraw boolean default false
) returns jsonb
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
  v_n int;
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
      -- The event first, so it can still read the stage the row is leaving.
      insert into public.application_events
        (application_id, actor_id, kind, body, from_stage_key, to_stage_key)
        select a.id, v_me, 'stage_change', v_reason, a.stage_key, 'withdrawn'
          from public.applications a
         where a.job_id = v_job.id
           and a.stage_key not in ('hired', 'rejected', 'withdrawn');
      get diagnostics v_n = row_count;
      update public.applications
         set stage_key = 'withdrawn', withdrawn_reason = v_reason,
             sub_status_key = (select s.key from public.application_sub_statuses s
                                where s.key = 'job_closed' and s.stage_key = 'withdrawn'
                                  and s.archived_at is null)
       where job_id = v_job.id
         and stage_key not in ('hired', 'rejected', 'withdrawn');
      v_withdrawn := v_withdrawn + v_n;
    end if;
  end loop;

  return jsonb_build_object('closed', v_closed, 'already_closed', v_already, 'withdrawn', v_withdrawn);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function app.reason_sub_status(text, text), app.backfill_sub_statuses() from public;
revoke all on function public.set_application_status(uuid[], text, text) from public, anon;
grant execute on function public.set_application_status(uuid[], text, text) to authenticated;

commit;
