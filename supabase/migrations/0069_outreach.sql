-- 0069_outreach.sql
-- Outreach — sub-statuses inside New and Screening (plan 054). The blueprint
-- keeps the seven stages, so "have we contacted this person, and did they
-- answer?" lives inside `new` and `screening` as a sub-status: a holding-wide
-- vocabulary, a default set by trigger on every write path, one RPC that logs
-- the same outreach on one or many applications, and "not responding" derived
-- from the last activity, never stored.
--
-- Order: lookup → column → default → Zoho mapping → backfill → trigger →
-- events → RPC → not responding → grants → report. The backfill runs before
-- the trigger exists (the 0067 discipline), so it writes no events and meets
-- no guard.

-- ---------------------------------------------------------------- lookup
-- One holding-wide vocabulary. `archived_at` is the retirement path; there is
-- no per-company list. Only `new` and `screening` carry sub-statuses — the
-- other stages are already an answer.
create table public.application_sub_statuses (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  stage_key text not null references public.application_stages(key),
  label text not null,
  sort_order int not null default 0,
  archived_at timestamptz
);
insert into public.application_sub_statuses (key, stage_key, label, sort_order) values
  ('applied',             'new',       'Applied',                          10),
  ('sourced',             'new',       'Sourced — not yet contacted',      20),
  ('contact_attempted',   'new',       'Contact attempted — no answer yet', 30),
  ('contacted',           'screening', 'In conversation',                  10),
  ('interested',          'screening', 'Interested',                       20),
  ('awaiting_evaluation', 'screening', 'Awaiting evaluation',              30),
  ('qualified',           'screening', 'Qualified — ready for interview',  40);
alter table public.application_sub_statuses enable row level security;
create policy read_all on public.application_sub_statuses for select to authenticated using (true);
create policy admin_write on public.application_sub_statuses for all to authenticated
  using (app.is_admin()) with check (app.is_admin());
grant select on public.application_sub_statuses to authenticated;
grant all on public.application_sub_statuses to service_role;

-- ---------------------------------------------------------------- column
alter table public.applications
  add column sub_status_key text references public.application_sub_statuses(key);
create index applications_sub_status_idx
  on public.applications (company_id, sub_status_key) where sub_status_key is not null;

-- --------------------------------------------------------------- default
-- At `new` the answer is how the person arrived: we went to them (head hunt,
-- a LinkedIn capture, an import of unknown provenance) or they came to us.
-- Every other stage takes its first sub-status by sort_order, null when it
-- has none.
create or replace function app.default_sub_status(p_stage text, p_source_key text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_stage = 'new' then
      case when coalesce(p_source_key, '') in ('head_hunt', 'linkedin_profile', 'imported')
           then 'sourced' else 'applied' end
    else (select s.key from public.application_sub_statuses s
           where s.stage_key = p_stage and s.archived_at is null
           order by s.sort_order, s.key limit 1)
  end
$$;

-- ----------------------------------------------------------- zoho status
-- D5's mapping, in one place: the backfill is its only caller and the smoke
-- asserts the function itself, so the mapping is never copied. Null for a
-- status Zoho Recruit did not set, or set in a word we do not map.
create or replace function app.zoho_sub_status(p_status text) returns text
language sql immutable security definer set search_path = public as $$
  select case coalesce(p_status, '')
    when 'Associated'             then 'sourced'
    when 'New'                    then 'sourced'
    when 'Attempted to Contact'   then 'contact_attempted'
    when 'Not Contacted'          then 'contact_attempted'
    when 'Not contacted'          then 'contact_attempted'
    when 'Contacted'              then 'contacted'
    when 'Interested'             then 'interested'
    when 'Waiting-for-Evaluation' then 'awaiting_evaluation'
    when 'Qualified'              then 'qualified'
    else null
  end
$$;

-- -------------------------------------------------------------- backfill
-- The Zoho Recruit status the import kept on the row (0067) is the only
-- record of what actually happened; everything else falls through to the
-- default. Other stages stay null. No events: this is history, not work.
-- The join to the lookup is the stage guard: a Zoho status that names a
-- sub-status of the other stage (an "Interested" row left at new) falls
-- through to the default like any unmapped one.
update public.applications a
   set sub_status_key = coalesce(
     (select s.key from public.application_sub_statuses s
       where s.stage_key = a.stage_key and s.archived_at is null
         and s.key = app.zoho_sub_status(a.custom->'zoho'->>'status')),
     app.default_sub_status(a.stage_key, a.source_key))
 where a.stage_key in ('new', 'screening');

-- --------------------------------------------------------------- trigger
-- The default belongs to the database, so the app's client-side stage moves,
-- the RPCs, the careers site and the import all get it without changing.
-- t3_… sorts after t0_guard_contact and t1_sync_company, before the
-- t8_touch_candidate / t9_notify pair (0067's naming note).
create or replace function app.applications_sub_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- On insert a key of another stage is corrected, never refused: an import
  -- of thousands of rows must not die on one status nobody recognises.
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
  -- Either the stage moved (whatever the row carried belongs to the stage it
  -- left) or the sub-status was cleared — and a row inside New or Screening
  -- always carries one. Both take the stage's default, null where it has none.
  if new.stage_key is distinct from old.stage_key or new.sub_status_key is null then
    new.sub_status_key := app.default_sub_status(new.stage_key, new.source_key);
    return new;
  end if;
  -- The stage stands and the key names another stage's sub-status.
  raise exception '"%" is not a sub-status of the % stage.', new.sub_status_key, new.stage_key
    using errcode = '22023';
end $$;
create trigger t3_sub_status before insert or update of stage_key, sub_status_key
  on public.applications
  for each row execute function app.applications_sub_status();

-- ---------------------------------------------------------------- events
-- Outreach joins the three kinds the timeline already knows. The sub-status
-- pair carries no foreign key: history outlives a retired key.
alter table public.application_events drop constraint application_events_kind_check;
alter table public.application_events add constraint application_events_kind_check
  check (kind in ('stage_change', 'note', 'interview_feedback', 'outreach'));
alter table public.application_events
  add column from_sub_status_key text,
  add column to_sub_status_key text;

-- ------------------------------------------------------------------- RPC
-- One door for one row and for fifty: the same event, the same sub-status.
-- All-or-nothing — the first refusal aborts the call, so a bulk log never
-- half-lands.
create or replace function public.log_outreach(
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
    if v_app.stage_key not in ('new', 'screening') then
      raise exception '% is at % — outreach is logged at New or Screening.', v_app.full_name, v_app.stage_label
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

-- -------------------------------------------------------- not responding
-- The rule, in one place, for the report and for the app to mirror: an
-- application on a live job (ready / open / on_hold), at `sourced`,
-- `contact_attempted` or `contacted`, whose last activity — the newest
-- application_event, else received_at — falls on a UTC *date* more than 30
-- days before today. Dates, not instants, so the badge and the tile agree
-- with the app's todayDb(): exactly 30 days ago is still answering, 31 is
-- not. Derived, never stored: the day it becomes false, it is false.
create or replace function app.not_responding(a public.applications) returns boolean
language sql stable security definer set search_path = public as $$
  select a.sub_status_key is not null
     and a.stage_key in ('new', 'screening')
     and a.sub_status_key in ('sourced', 'contact_attempted', 'contacted')
     and exists (select 1 from public.jobs j
                  where j.id = a.job_id and j.status in ('ready', 'open', 'on_hold'))
     and coalesce((select max(e.created_at) from public.application_events e
                    where e.application_id = a.id), a.received_at)::date
         < current_date - 30
$$;

-- ---------------------------------------------------------------- grants
-- Trigger and report helpers only; both are called from security-definer
-- code owned by postgres.
revoke all on function
  app.default_sub_status(text, text),
  app.zoho_sub_status(text),
  app.not_responding(public.applications)
from public;
revoke all on function public.log_outreach(uuid[], text, text) from public, anon;
grant execute on function public.log_outreach(uuid[], text, text) to authenticated;

-- ---------------------------------------------------------------- report
-- recruitment_report (0067) re-created with one line changed: attention
-- gains "not responding" beside the three counts it already carries.
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
