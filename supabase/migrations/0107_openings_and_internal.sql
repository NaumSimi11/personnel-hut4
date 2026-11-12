-- 0107_openings_and_internal.sql
-- The opening and the internal applicant (Hiring Module user flows, 11 Nov
-- 2026: 2.4, 3.2, 3.4, 3.5, section 4 "Internal applicant"; screens 9.5,
-- 9.6, 9.7).
--
--   * Positions (2.4, 7.3): one per approved headcount, counted rather than
--     stored — job_positions() says how many are filled and open.
--   * Hiring team (3.2): people added to a job see its candidates the way its
--     hiring manager does (0100) and may score its interviews; the team's
--     role is a label (recruiter, interviewer, assessor, panel, director).
--   * Postings (3.4): each channel of a job may carry its own title, text,
--     salary line, audience and publish window. The careers page shows a job
--     only inside its careers window.
--   * Internal job board (3.5): channel `internal`. Every signed-in person sees
--     the jobs live there, across the group, and can apply in one step; the
--     application's source is `internal_board` and its candidate is linked to
--     the person.
--   * An internal applicant is hidden from their current manager until the
--     application reaches Offer (section 4); the form tells them so.

begin;

-- ---------------------------------------------------------------- team
create table public.job_team (
  job_id uuid not null references public.jobs(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  role text not null default 'interviewer' check (role in ('recruiter', 'interviewer', 'assessor', 'panel', 'director')),
  added_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  primary key (job_id, person_id)
);
alter table public.job_team enable row level security;
create policy sel on public.job_team for select to authenticated
  using (person_id = app.current_person_id()
         or exists (select 1 from public.jobs j where j.id = job_id and app.has_capability(j.company_id, 'jobs.view')));
create policy write on public.job_team for all to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id and app.has_capability(j.company_id, 'jobs.edit')))
  with check (exists (select 1 from public.jobs j where j.id = job_id and app.has_capability(j.company_id, 'jobs.edit')));
grant select, insert, update, delete on public.job_team to authenticated;
grant all on public.job_team to service_role;
create trigger audit after insert or update or delete on public.job_team
  for each row execute function app.audit();

create or replace function app.notify_job_team() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_job record;
begin
  if new.person_id = app.current_person_id() then return new; end if;
  select id, company_id, title into v_job from public.jobs where id = new.job_id;
  perform app.notify(new.person_id, v_job.company_id, 'hiring.team',
    'You are on the hiring team: ' || v_job.title, 'Role: ' || new.role || ' · you can see its candidates',
    '/hiring/jobs/' || v_job.id, 'job', v_job.id, 'hiring.team:' || v_job.id || ':' || new.person_id);
  return new;
end $$;
create trigger t9_notify after insert on public.job_team
  for each row execute function app.notify_job_team();

-- The HM's view of a job (0100) now covers its team as well.
create or replace function app.is_hiring_manager_of(p_job uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_job is not null and exists (
    select 1 from public.jobs j
     where j.id = p_job
       and ((j.hiring_manager_id = app.current_person_id() and app.has_capability(j.company_id, 'candidates.assigned'))
            or exists (select 1 from public.job_team t where t.job_id = j.id and t.person_id = app.current_person_id())))
$$;

-- -------------------------------------------------------------- positions
create or replace function public.job_positions(p_job_ids uuid[])
returns table (job_id uuid, headcount int, filled int, open int)
language sql stable security definer set search_path = public as $$
  select j.id, app.job_headcount(j.id),
         (select count(*)::int from public.applications a where a.job_id = j.id and a.stage_key = 'hired'),
         greatest(app.job_headcount(j.id) - (select count(*)::int from public.applications a where a.job_id = j.id and a.stage_key = 'hired'), 0)
    from public.jobs j
   where j.id = any (coalesce(p_job_ids, '{}'))
     and (app.has_capability(j.company_id, 'jobs.view') or app.is_hiring_manager_of(j.id))
$$;
grant execute on function public.job_positions(uuid[]) to authenticated;

-- --------------------------------------------------------------- postings
alter table public.job_channels
  add column posting_title text check (posting_title is null or length(posting_title) <= 120),
  add column posting_text text check (posting_text is null or length(posting_text) <= 20000),
  add column salary_display text check (salary_display is null or length(salary_display) <= 120),
  add column publish_from date,
  add column publish_until date,
  add constraint job_channels_window check (publish_until is null or publish_from is null or publish_until >= publish_from);

insert into public.channels (key, label, kind) values ('internal', 'Internal job board', 'careers')
on conflict (key) do nothing;
insert into public.candidate_sources (key, label, sort_order) values ('internal_board', 'Internal job board', 75)
on conflict (key) do nothing;

-- --------------------------------------------------- the internal board
alter table public.candidates add column person_id uuid unique references public.people(id) on delete set null;

/** Jobs live on the internal board today, across the group. Any signed-in person. */
create or replace function public.internal_jobs() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', j.id, 'title', coalesce(jc.posting_title, j.title), 'company', co.name,
           'text', coalesce(jc.posting_text, j.description, ''), 'salary', jc.salary_display,
           'until', jc.publish_until,
           'applied', exists (select 1 from public.applications a join public.candidates c on c.id = a.candidate_id
                               where a.job_id = j.id and c.person_id = app.current_person_id()))
         order by co.name, j.title), '[]'::jsonb)
    from public.jobs j
    join public.job_channels jc on jc.job_id = j.id and jc.channel_key = 'internal' and jc.status = 'live'
    join public.companies co on co.id = j.company_id
   where app.current_person_id() is not null
     and j.status = 'open'
     and (jc.publish_from is null or jc.publish_from <= current_date)
     and (jc.publish_until is null or jc.publish_until >= current_date)
$$;
grant execute on function public.internal_jobs() to authenticated;

create or replace function public.apply_internally(p_job_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_person record;
  v_candidate uuid;
  v_app uuid;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if length(coalesce(v_note, '')) > 2000 then
    raise exception 'Keep the note to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.jobs j join public.job_channels jc on jc.job_id = j.id
                  where j.id = p_job_id and j.status = 'open' and jc.channel_key = 'internal' and jc.status = 'live'
                    and (jc.publish_from is null or jc.publish_from <= current_date)
                    and (jc.publish_until is null or jc.publish_until >= current_date)) then
    raise exception 'This job is not open on the internal board.' using errcode = '22023';
  end if;
  select id, full_name, work_email, phone into v_person from public.people where id = v_me;
  select id into v_candidate from public.candidates where person_id = v_me;
  perform set_config('app.candidate_rpc', 'on', true);
  if v_candidate is null then
    insert into public.candidates (full_name, email, person_id, source_key, sourced_by)
    values (v_person.full_name, v_person.work_email, v_me, 'internal_board', v_me)
    returning id into v_candidate;
  end if;
  v_app := app.open_application(v_candidate, p_job_id, 'internal_board', true);
  perform set_config('app.candidate_rpc', 'off', true);
  if v_note is not null then
    insert into public.application_events (application_id, actor_id, kind, body)
    values (v_app, v_me, 'note', 'From the internal applicant: ' || v_note);
  end if;
  return jsonb_build_object('application_id', v_app);
end $$;
grant execute on function public.apply_internally(uuid, text) to authenticated;

-- --------------------------- hidden from the applicant's manager (section 4)
/** True when the signed-in person manages the candidate's current employment and the application is not yet at Offer. */
create or replace function app.hidden_from_manager(p_candidate uuid, p_stage text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_stage not in ('offer', 'hired')
     and not app.is_admin()
     and exists (select 1 from public.candidates c
                   join public.employment_periods ep on ep.person_id = c.person_id
                  where c.id = p_candidate and c.person_id is not null
                    and ep.manager_id = app.current_person_id()
                    and ep.status in ('pre_start', 'active'))
$$;
grant execute on function app.hidden_from_manager(uuid, text) to authenticated;

create policy hide_from_manager on public.applications as restrictive for select to authenticated
  using (not app.hidden_from_manager(candidate_id, stage_key));

commit;
