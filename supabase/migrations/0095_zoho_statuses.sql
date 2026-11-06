-- 0095_zoho_statuses.sql
-- Zoho's vocabulary (plan 075): the four hiring stages Zoho has — Screening,
-- Interview, Offered, Hired — and its 37 statuses, each with an outcome.
-- Rejected and withdrawn stop being stages; they become what a status
-- *means* (`outcome`), so an application keeps the stage it reached when it
-- ended. `applications.in_play` says whether it still counts (open outcome,
-- not closed) and `closed_at` / `closed_reason` mark a closure by the system
-- (a job closed) without touching the status.
--
-- Destructive by design: the old vocabulary and the three old stages go, so
-- it refuses to run over data. The applications are re-imported afterwards.
-- The functions that still name the old stages are rewritten by 0096.
-- One transaction: a half-seeded vocabulary is worse than none.

begin;

-- ----------------------------------------------------------------- guard
do $$
begin
  if (select count(*) from public.applications) <> 0
     or (select count(*) from public.application_events) <> 0 then
    raise exception '0095 replaces the stages and statuses and needs an empty pipeline: applications and application_events must have no rows.';
  end if;
end $$;

-- --------------------------------------------------------------- columns
alter table public.application_sub_statuses
  add column outcome text check (outcome in ('open', 'rejected', 'withdrew', 'hired'));
alter table public.applications
  add column in_play boolean not null default true,
  add column closed_at timestamptz,
  add column closed_reason text check (char_length(closed_reason) <= 2000);

-- ------------------------------------------------------- stages, cleared
delete from public.application_sub_statuses;
delete from public.application_stages where key in ('new', 'rejected', 'withdrawn');
update public.application_stages set label = 'Offered' where key = 'offer';
update public.application_stages set sort_order = case key
  when 'screening' then 10 when 'interview' then 20
  when 'offer' then 30 when 'hired' then 40 end;
alter table public.applications alter column stage_key set default 'screening';

-- -------------------------------------------------------------- the seed
insert into public.application_sub_statuses (key, stage_key, label, sort_order, outcome) values
  ('applied',                     'screening', 'New',                                     10, 'open'),
  ('sourced',                     'screening', 'Associated',                              20, 'open'),
  ('not_contacted',               'screening', 'Not Contacted',                           30, 'open'),
  ('contact_attempted',           'screening', 'Attempted to Contact',                    40, 'open'),
  ('contacted',                   'screening', 'Contacted',                               50, 'open'),
  ('no_response',                 'screening', 'Not responding',                          60, 'withdrew'),
  ('interested',                  'screening', 'Interested',                              70, 'open'),
  ('not_interested',              'screening', 'Not Interested',                          80, 'withdrew'),
  ('qualified',                   'screening', 'Qualified',                               90, 'open'),
  ('waiting_for_evaluation',      'screening', 'Waiting-for-Evaluation',                 100, 'open'),
  ('unqualified',                 'screening', 'Unqualified',                            110, 'rejected'),
  ('rejected_for_interview',      'screening', 'Rejected-for-Interview',                 120, 'rejected'),
  ('contact_in_future',           'screening', 'Contact in Future',                      130, 'withdrew'),
  ('never_contact',               'screening', 'NEVER to be contacted again',            140, 'withdrew'),
  ('interview_to_schedule',       'interview', 'Interview-to-be-Scheduled',               10, 'open'),
  ('interview_scheduled',         'interview', 'Interview-Scheduled',                     20, 'open'),
  ('interview_in_progress',       'interview', 'Interview-in-Progress',                   30, 'open'),
  ('interview_hr',                'interview', 'Interview 1 - HR',                        40, 'open'),
  ('interview_stakeholders',      'interview', 'Interview 2 - Stakeholders',              50, 'open'),
  ('interview_other_stakeholder', 'interview', 'Interview 3 - Other stakeholder',         60, 'open'),
  ('interview_other_stakeholders','interview', 'Interview 4 - Other stakeholders',        70, 'open'),
  ('interview_task',              'interview', 'Task',                                    80, 'open'),
  ('no_show',                     'interview', 'No-Show',                                 90, 'open'),
  ('interview_feedback_due',      'interview', 'Feedback to be provided from an Interview', 100, 'open'),
  ('submitted_to_manager',        'interview', 'Submitted-to-hiring manager',            110, 'open'),
  ('interview_on_hold',           'interview', 'On-Hold',                                120, 'open'),
  ('rejected_general',            'interview', 'Rejected',                               130, 'rejected'),
  ('rejected_by_hr',              'interview', 'Rejected by HR',                         140, 'rejected'),
  ('rejected_by_manager',         'interview', 'Rejected by hiring manager',             150, 'rejected'),
  ('rejected_after_interview',    'interview', 'Rejected by Manager - Interview',        160, 'rejected'),
  ('rejected_hirable',            'interview', 'Rejected-Hirable',                       170, 'rejected'),
  ('candidate_withdrew',          'interview', 'Withdraw Application',                   180, 'withdrew'),
  ('to_be_offered',               'offer',     'To-be-Offered',                           10, 'open'),
  ('offer_made',                  'offer',     'Offer-Made',                              20, 'open'),
  ('offer_declined',              'offer',     'Offer-Declined',                          30, 'withdrew'),
  ('offer_withdrawn',             'offer',     'Offer-Withdrawn',                         40, 'rejected'),
  ('hired',                       'hired',     'Hired',                                   10, 'hired');
alter table public.application_sub_statuses alter column outcome set not null;
-- Hired is the one stage of outcome hired, and outcome hired lives only there:
-- an open status on Hired would count a hire as still in play.
alter table public.application_sub_statuses add constraint application_sub_statuses_hired_stage
  check ((stage_key = 'hired') = (outcome = 'hired'));

-- ------------------------------------------------- an outcome stays put
-- Flipping what a status means would silently re-count every application
-- that carries it (in_play is set when the application is written).
create or replace function app.sub_status_outcome_stays() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.outcome is distinct from old.outcome
     and exists (select 1 from public.applications a where a.sub_status_key = old.key) then
    raise exception '"%" is in use — its outcome cannot change.', old.label using errcode = '22023';
  end if;
  return new;
end $$;
create trigger t1_outcome_stays before update of outcome on public.application_sub_statuses
  for each row execute function app.sub_status_outcome_stays();

-- --------------------------------------------------------------- default
-- Screening starts with how the person arrived (we went to them, or they
-- came to us); every other stage starts at its first live status.
create or replace function app.default_sub_status(p_stage text, p_source_key text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_stage = 'screening' then
      case when coalesce(p_source_key, '') in ('head_hunt', 'linkedin_profile', 'imported')
           then 'sourced' else 'applied' end
    else (select s.key from public.application_sub_statuses s
           where s.stage_key = p_stage and s.archived_at is null
           order by s.sort_order, s.key limit 1)
  end
$$;

-- --------------------------------------------------------------- trigger
-- 0088's guard (the status belongs to the stage and is not retired), plus
-- in_play: the status's outcome is open and nothing has closed the row.
create or replace function app.applications_sub_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_label text; v_outcome text;
begin
  if tg_op = 'INSERT' then
    if new.sub_status_key is null
       or not exists (select 1 from public.application_sub_statuses s
                       where s.key = new.sub_status_key
                         and s.stage_key = new.stage_key
                         and s.archived_at is null) then
      new.sub_status_key := app.default_sub_status(new.stage_key, new.source_key);
    end if;
  elsif new.stage_key is distinct from old.stage_key
        or new.sub_status_key is distinct from old.sub_status_key then
    if new.sub_status_key is null
       or not exists (select 1 from public.application_sub_statuses s
                       where s.key = new.sub_status_key
                         and s.stage_key = new.stage_key
                         and s.archived_at is null) then
      if new.stage_key is distinct from old.stage_key or new.sub_status_key is null then
        new.sub_status_key := app.default_sub_status(new.stage_key, new.source_key);
      else
        select s.label into v_label from public.application_sub_statuses s
         where s.key = new.sub_status_key and s.stage_key = new.stage_key and s.archived_at is not null;
        if found then
          raise exception '"%" is retired — pick another status.', v_label using errcode = '22023';
        end if;
        raise exception '"%" is not a sub-status of the % stage.', new.sub_status_key, new.stage_key
          using errcode = '22023';
      end if;
    end if;
  end if;
  select s.outcome into v_outcome from public.application_sub_statuses s where s.key = new.sub_status_key;
  new.in_play := coalesce(v_outcome = 'open', true) and new.closed_at is null;
  return new;
end $$;
drop trigger t3_sub_status on public.applications;
-- in_play is in the list so a direct write of it is recomputed, never kept.
create trigger t3_sub_status before insert or update of stage_key, sub_status_key, closed_at, in_play
  on public.applications
  for each row execute function app.applications_sub_status();

-- ----------------------------------------------------------------- index
-- One application in play per candidate and job; an ended one lets them
-- apply again.
drop index public.applications_one_open_per_candidate;
create unique index applications_one_open_per_candidate
  on public.applications (job_id, candidate_id) where in_play;
create index applications_in_play_job_idx on public.applications (job_id) where in_play;

commit;
