-- 0100_hiring_manager_role.sql
-- The hiring manager (HM) as a real, narrow role (feedback: "Developer notes
-- Hiring Manager (HM) role", 2026-11-10).
--
-- What the note asked, and the rule chosen for each:
--
--   * HM sees only the candidates for the openings they are hiring manager
--     for. -> A new capability, `candidates.assigned`, means exactly that: in
--     a company where you hold it, you see the applications on the jobs that
--     name you as `hiring_manager_id`, and nothing else. `candidates.view`
--     still means the whole company, so HR is unchanged.
--   * HM does not set statuses in the standard flow, and cannot delete. ->
--     Both already need `candidates.review`, which the HM does not get.
--   * Three statuses only the HM sets: contact, do_not_contact,
--     contact_in_future. -> `application_sub_statuses.hm_only`. On a job that
--     names a hiring manager, only that person (or an admin) may put an
--     application on one; on a job with nobody named, HR keeps them, so a job
--     without an HM is never stuck. HR moves the application on from there
--     (contact -> contacted -> ...), as before.
--   * HM fills nothing in once the candidate is at Offer. -> The HM's one
--     door, `hm_set_status`, works at Screening only, and an HM scores an
--     interview only while the application is at Screening or Interview. At
--     Offer and Hired the HM reads (offer included) and does not write.
--   * Notify the HM at Offer. -> When an application reaches Offer, the job's
--     hiring manager gets a notification (and its email), unless they moved
--     it there themselves.
--
-- The "Hiring Manager" preset swaps candidates.view / candidates.review for
-- the new capability, and so do the grants made from it, unless somebody has
-- since given such a grant offer.approve or candidates.source (which build
-- on candidates.view) — those were turned into recruiters on purpose and are
-- left alone.

begin;

-- --------------------------------------------------------------- capability
insert into public.capabilities (key, group_name, label, sensitive, sort_order) values
  ('candidates.assigned', 'Recruitment', 'See and judge candidates on own openings (hiring manager)', false, 65);
insert into public.capability_dependencies (capability_key, requires_key) values
  ('candidates.assigned', 'jobs.view');

-- ------------------------------------------------------------------ preset
update public.permission_presets
   set description = 'Sees and judges only the candidates on openings they are hiring manager for'
 where name = 'Hiring Manager' and company_id is null;
delete from public.preset_capabilities pc
 using public.permission_presets p
 where pc.preset_id = p.id and p.name = 'Hiring Manager' and p.company_id is null
   and pc.capability_key in ('candidates.view', 'candidates.review');
insert into public.preset_capabilities (preset_id, capability_key)
select p.id, 'candidates.assigned' from public.permission_presets p
 where p.name = 'Hiring Manager' and p.company_id is null
on conflict do nothing;

-- The grants made from it, unless turned into something else since.
create temp table hm_grants on commit drop as
select g.id from public.access_grants g
  join public.permission_presets p on p.id = g.source_preset_id
 where p.name = 'Hiring Manager'
   and not exists (select 1 from public.grant_capabilities gc
                    where gc.grant_id = g.id and gc.capability_key in ('offer.approve', 'candidates.source'));
delete from public.grant_capabilities gc using hm_grants h
 where gc.grant_id = h.id and gc.capability_key in ('candidates.view', 'candidates.review');
insert into public.grant_capabilities (grant_id, capability_key)
select h.id, 'candidates.assigned' from hm_grants h
on conflict do nothing;
do $$ begin
  raise notice 'Hiring Manager grants narrowed to own openings: %', (select count(*) from hm_grants);
end $$;

-- ------------------------------------------------------- the job's HM
-- The hiring manager was only ever written on the request, and the jobs
-- imported from Zoho have no request. The job now carries its own: filled
-- from the request when the job is made or the request's HM changes, and
-- set on the job page by whoever may edit the job.
alter table public.jobs add column hiring_manager_id uuid references public.people(id);
create index jobs_hiring_manager_idx on public.jobs (hiring_manager_id) where hiring_manager_id is not null;

alter table public.jobs disable trigger touch;
alter table public.jobs disable trigger audit;
update public.jobs j set hiring_manager_id = r.hiring_manager_id
  from public.hiring_requests r
 where r.id = j.hiring_request_id and r.hiring_manager_id is not null and j.hiring_manager_id is null;
alter table public.jobs enable trigger touch;
alter table public.jobs enable trigger audit;

create or replace function app.jobs_hm_from_request() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.hiring_manager_id is null and new.hiring_request_id is not null then
    select r.hiring_manager_id into new.hiring_manager_id
      from public.hiring_requests r where r.id = new.hiring_request_id;
  end if;
  return new;
end $$;
create trigger t3_hm_from_request before insert on public.jobs
  for each row execute function app.jobs_hm_from_request();

create or replace function app.requests_hm_to_jobs() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.hiring_manager_id is distinct from old.hiring_manager_id then
    update public.jobs set hiring_manager_id = new.hiring_manager_id
     where hiring_request_id = new.id
       and hiring_manager_id is not distinct from old.hiring_manager_id;
  end if;
  return new;
end $$;
create trigger t8_hm_to_jobs after update of hiring_manager_id on public.hiring_requests
  for each row execute function app.requests_hm_to_jobs();

-- ------------------------------------------------------------------ helpers
/** Is the signed-in person the hiring manager of this job, holding candidates.assigned there? */
create or replace function app.is_hiring_manager_of(p_job uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_job is not null and exists (
    select 1 from public.jobs j
     where j.id = p_job
       and j.hiring_manager_id = app.current_person_id()
       and app.has_capability(j.company_id, 'candidates.assigned'))
$$;

create or replace function app.hm_sees_application(p_application uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.applications a
                  where a.id = p_application and app.is_hiring_manager_of(a.job_id))
$$;

create or replace function app.hm_sees_candidate(p_candidate uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.applications a
                  where a.candidate_id = p_candidate and app.is_hiring_manager_of(a.job_id))
$$;

/** A note the HM may read: about a candidate on their job, untagged or tagged with that job's company. */
create or replace function app.hm_sees_note(p_candidate uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.applications a
                  where a.candidate_id = p_candidate
                    and (p_company is null or p_company = a.company_id)
                    and app.is_hiring_manager_of(a.job_id))
$$;

/** The HM scores while the application is still being decided: Screening or Interview, in play. */
create or replace function app.hm_may_score(p_interview uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.interviews i
                   join public.applications a on a.id = i.application_id
                  where i.id = p_interview
                    and a.stage_key in ('screening', 'interview')
                    and a.in_play and a.closed_at is null
                    and app.is_hiring_manager_of(a.job_id))
$$;

grant execute on function app.is_hiring_manager_of(uuid), app.hm_sees_application(uuid),
  app.hm_sees_candidate(uuid), app.hm_sees_note(uuid, uuid), app.hm_may_score(uuid) to authenticated;

-- ---------------------------------------------------------------------- RLS
-- Extra permissive policies: they add the HM's own openings to what the
-- existing policies already allow, and take nothing away.
create policy sel_hm on public.applications for select to authenticated
  using (app.is_hiring_manager_of(job_id));
create policy sel_hm on public.application_events for select to authenticated
  using (app.hm_sees_application(application_id));
create policy sel_hm on public.candidates for select to authenticated
  using (app.hm_sees_candidate(id));
create policy sel_hm on public.candidate_files for select to authenticated
  using (app.hm_sees_candidate(candidate_id));
create policy sel_hm on public.candidate_notes for select to authenticated
  using (app.hm_sees_note(candidate_id, company_id));
create policy sel_hm on public.application_files for select to authenticated
  using (app.hm_sees_application(application_id));
create policy sel_hm on public.interviews for select to authenticated
  using (app.hm_sees_application(application_id));
create policy sel_hm on public.interview_panel for select to authenticated
  using (exists (select 1 from public.interviews i
                  where i.id = interview_id and app.hm_sees_application(i.application_id)));
-- The blind rule holds for the HM too: colleagues' cards once theirs is in.
create policy sel_hm on public.scorecards for select to authenticated
  using (app.hm_sees_application(application_id)
         and (not app.is_on_panel(interview_id) or app.has_scored(interview_id)));
create policy ins_hm on public.scorecards for insert to authenticated
  with check (author_id = app.current_person_id() and app.hm_may_score(interview_id));
create policy sel_hm on public.offers for select to authenticated
  using (app.hm_sees_application(application_id));

create policy "candidate files: hiring manager read" on storage.objects
  for select to authenticated
  using (bucket_id = 'candidate-files'
         and (app.hm_sees_candidate(app.candidate_object_candidate(name))
              or (split_part(name, '/', 1)
                    ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                  and app.hm_sees_application(split_part(name, '/', 1)::uuid))));

-- ------------------------------------------------------------- HM statuses
alter table public.application_sub_statuses
  add column hm_only boolean not null default false;
comment on column public.application_sub_statuses.hm_only is
  'Set only by the job''s hiring manager (or an admin) when the job names one (0100).';

insert into public.application_sub_statuses (key, stage_key, label, sort_order, outcome, hm_only)
values ('contact', 'screening', 'contact', 15, 'open', true);
update public.application_sub_statuses set hm_only = true
 where key in ('do_not_contact', 'contact_in_future');

-- Who may put an application on an HM status. Runs after t3_sub_status has
-- settled the key. The import and system writers (no signed-in person) pass.
create or replace function app.guard_hm_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_hm uuid;
  v_label text;
begin
  if current_setting('app.bulk_import', true) = 'on' or v_me is null then return new; end if;
  if tg_op = 'UPDATE' and new.sub_status_key is not distinct from old.sub_status_key then return new; end if;
  select s.label into v_label from public.application_sub_statuses s
   where s.key = new.sub_status_key and s.hm_only;
  if not found then return new; end if;
  select j.hiring_manager_id into v_hm from public.jobs j where j.id = new.job_id;
  if v_hm is null or v_hm = v_me or app.is_admin() then return new; end if;
  raise exception '"%" is the hiring manager''s call — % sets it for this job.', v_label, app.person_name(v_hm)
    using errcode = '42501';
end $$;
create trigger t4_hm_status before insert or update of sub_status_key on public.applications
  for each row execute function app.guard_hm_status();

-- ------------------------------------------------------------ hm_set_status
-- The hiring manager's one door: an HM status, at Screening, on their job.
create or replace function public.hm_set_status(p_application_id uuid, p_sub_status_key text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_note text := trim(coalesce(p_note, ''));
  v_status record;
  v_app record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if length(v_note) > 2000 then
    raise exception 'Keep the note to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  select s.key, s.label, s.stage_key, s.outcome, s.hm_only, s.archived_at into v_status
    from public.application_sub_statuses s where s.key = nullif(trim(coalesce(p_sub_status_key, '')), '');
  if not found or not v_status.hm_only or v_status.archived_at is not null then
    raise exception 'A hiring manager picks one of the hiring manager''s statuses.' using errcode = '22023';
  end if;

  select a.id, a.stage_key, a.sub_status_key, a.closed_at, a.withdrawn_reason, a.rejected_reason,
         j.hiring_manager_id, j.company_id, j.status as job_status, c.full_name,
         os.label as old_label, os.outcome as old_outcome, os.hm_only as old_hm_only
    into v_app
    from public.applications a
    join public.jobs j on j.id = a.job_id
    join public.candidates c on c.id = a.candidate_id
    left join public.application_sub_statuses os on os.key = a.sub_status_key
   where a.id = p_application_id;
  if not found then
    raise exception 'That application no longer exists.' using errcode = '22023';
  end if;
  if v_app.hiring_manager_id is distinct from v_me
     or not (app.has_capability(v_app.company_id, 'candidates.assigned')
             or app.has_capability(v_app.company_id, 'candidates.review')) then
    raise exception 'Only the job''s hiring manager sets this.' using errcode = '42501';
  end if;
  if v_app.closed_at is not null or v_app.job_status in ('closed', 'filled') then
    raise exception 'This job is closed. Nothing more to decide here.' using errcode = '22023';
  end if;
  if v_app.stage_key <> 'screening' then
    raise exception '% is past screening — HR takes it from here.', v_app.full_name using errcode = '22023';
  end if;
  -- An HR outcome (rejected, withdrawn) is HR's; the HM changes only an open
  -- status or their own earlier call.
  if v_app.old_outcome <> 'open' and not coalesce(v_app.old_hm_only, false) then
    raise exception '% is closed at screening ("%"). HR reopens it first.', v_app.full_name, v_app.old_label
      using errcode = '22023';
  end if;
  if v_app.sub_status_key = v_status.key then
    return jsonb_build_object('set', 0);
  end if;

  insert into public.application_events
    (application_id, actor_id, kind, body, from_stage_key, to_stage_key, from_sub_status_key, to_sub_status_key)
  values (v_app.id, v_me, 'outreach', nullif(v_note, ''), v_app.stage_key, 'screening', v_app.sub_status_key, v_status.key);
  begin
    update public.applications
       set sub_status_key = v_status.key,
           withdrawn_reason = case
             when v_status.outcome = 'withdrew'
              and (btrim(coalesce(v_app.withdrawn_reason, '')) = ''
                   or lower(btrim(v_app.withdrawn_reason)) = lower(btrim(coalesce(v_app.old_label, ''))))
             then v_status.label
             when v_status.outcome = 'open'
              and lower(btrim(coalesce(v_app.withdrawn_reason, ''))) = lower(btrim(coalesce(v_app.old_label, '')))
             then null
             else withdrawn_reason end
     where id = v_app.id;
  exception when unique_violation then
    raise exception '% already has an open application for this job.', v_app.full_name using errcode = '22023';
  end;
  return jsonb_build_object('set', 1);
end $$;
grant execute on function public.hm_set_status(uuid, text, text) to authenticated;

-- ------------------------------------------------------- notify HM at Offer
create or replace function app.notify_hm_at_offer() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_hm uuid; v_job text; v_candidate text;
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if new.stage_key <> 'offer' or old.stage_key = 'offer' then return new; end if;
  select j.hiring_manager_id, j.title into v_hm, v_job from public.jobs j where j.id = new.job_id;
  if v_hm is null or v_hm = app.current_person_id() then return new; end if;
  select full_name into v_candidate from public.candidates where id = new.candidate_id;
  perform app.notify(v_hm, new.company_id, 'candidate.offer',
    'Offer stage: ' || coalesce(v_candidate, 'Candidate'),
    coalesce(v_job, 'Role') || ' · HR is preparing the offer',
    '/hiring/applications/' || new.id, 'application', new.id,
    'candidate.offer:' || new.id);
  return new;
end $$;
create trigger t9_notify_hm_offer after update of stage_key on public.applications
  for each row execute function app.notify_hm_at_offer();

-- ------------------------------------------------- who may be named HM
-- 0059's list, plus anyone holding the hiring manager capability.
create or replace function public.hiring_managers(p_company_id uuid)
returns table (id uuid, full_name text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.full_name
  from public.people p
  where exists (
      select 1
      from public.access_grants g
      join public.grant_capabilities gc on gc.grant_id = g.id
      where g.person_id = p.id
        and g.company_id = p_company_id
        and gc.capability_key in (
          'candidates.review', 'candidates.assigned', 'jobs.approve', 'jobs.edit',
          'employment.edit', 'people.view', 'tasks.assign')
    )
    or exists (select 1 from public.platform_admins pa where pa.person_id = p.id)
  order by p.full_name
$$;
grant execute on function public.hiring_managers(uuid) to authenticated;

-- ----------------------------------------------- opening counts for the HM
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
       and (a.company_id in (select c.id from public.companies c where app.has_capability(c.id, 'candidates.view'))
            or app.is_hiring_manager_of(a.job_id))
     group by a.job_id;
end $$;
grant execute on function public.opening_counts(uuid[]) to authenticated;

commit;
