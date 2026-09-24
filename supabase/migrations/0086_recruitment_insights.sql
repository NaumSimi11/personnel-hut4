-- 0086_recruitment_insights.sql
-- Recruitment insights (plan 067): the time side of hiring that the Zoho
-- Recruit home showed and PeopleOS did not — how long each opening has been
-- open and how long it took to fill, how long each hire took, how many
-- offers were accepted, and a feed of who moved which candidate.
--
-- A job had no date for the day it opened: created_at is when somebody
-- started the draft, which can be weeks before it went live. So the job now
-- carries `opened_at`, stamped by a trigger the first time it goes live and
-- never moved after — reopening a job does not restart its clock, the same
-- way Zoho counts "since creation".
--
-- Order: column → backfill → stamp trigger → recruitment_insights → grants.
-- One transaction: psql applies a file statement by statement, and a
-- failure between disabling and re-enabling the touch/audit triggers must
-- not leave them off, nor may a job open between the backfill and the
-- trigger and never be dated.

begin;

-- ---------------------------------------------------------------- column
alter table public.jobs add column opened_at timestamptz;

comment on column public.jobs.opened_at is
  'When the opening first went live. Set by the t3_opening_stamp trigger; never moves once set.';

-- -------------------------------------------------------------- backfill
-- A job the Zoho import wrote arrived with the status it had there and the
-- date Zoho created it: that date is the best one there is (its audit row
-- is the import, not the opening). Every other job opened when the audit
-- trail first saw it go live; a job that is past `ready` with no such row
-- (seeded, or opened before the audit trigger existed) falls back to its
-- creation. Drafts and ready jobs never opened, so they stay null.
--
-- The touch and audit triggers are held for the backfill: a column nobody
-- edited must not re-date every job's updated_at, nor add a thousand audit
-- rows that each claim a change.
alter table public.jobs disable trigger touch;
alter table public.jobs disable trigger audit;

update public.jobs j
set opened_at = case
  when j.custom ? 'zoho' then j.created_at
  else coalesce(
    (select min(l.at) from public.activity_log l
     where l.entity_type = 'jobs' and l.entity_id = j.id::text
       and l.after->>'status' = 'open'),
    j.created_at)
  end
where j.status in ('open', 'on_hold', 'filled', 'closed');

alter table public.jobs enable trigger touch;
alter table public.jobs enable trigger audit;

-- ---------------------------------------------------------- stamp trigger
-- Once set, opened_at is the job's own history: an update keeps the old
-- value whatever the client sends, so it can be neither forged nor cleared.
-- A job moving into `open` for the first time is stamped now. A job
-- inserted already past `ready` (the import) is dated by what it was given,
-- else its creation — it must have been live once. A job updated from draft
-- or ready straight to closed never went live, so it stays null.
create or replace function app.jobs_opening_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if old.opened_at is not null then
      new.opened_at := old.opened_at;
    elsif new.status = 'open' and old.status is distinct from 'open' then
      new.opened_at := now();
    else
      new.opened_at := null;
    end if;
  elsif new.status in ('open', 'on_hold', 'filled', 'closed') then
    new.opened_at := coalesce(new.opened_at, new.created_at, now());
  else
    new.opened_at := null;
  end if;
  return new;
end $$;

create trigger t3_opening_stamp before insert or update on public.jobs
  for each row execute function app.jobs_opening_stamp();

-- ---------------------------------------------------- recruitment_insights
-- One company, one date range — the Reports page's own filter.
--
--   fill      every opening still short of its headcount (open, on hold),
--             plus every opening whose headcount was completed in the
--             range, whatever its status now. Only hires made after the
--             job opened count toward filling it: an application hired
--             into an earlier life of the role did not fill this opening.
--             `days` runs from opened_at to the hire that completed the
--             headcount, or to today while it is still short. `late_days`
--             is how far that end is past the hiring request's target
--             start date (0 when on time or when no target was set).
--   hires     each hire in the range: applied → hired, in days. Names are
--             candidate data, so the list needs candidates.view; without
--             it the list is empty and `can_see_candidates` says why.
--   offers    offers created in the range that reached the candidate:
--             extended (still open), accepted, declined. The rate is
--             accepted / (accepted + declined) — an offer still out has no
--             answer yet and does not count against it.
--   activity  the latest stage changes in the range, newest first (60),
--             behind the same candidates.view.
--
-- The hire date is app.report_hires (0015): the first stage change into
-- `hired`, which for an imported application is Zoho's hired date.
create or replace function public.recruitment_insights(
  p_company_id uuid,
  p_from date,
  p_to date
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamptz;
  v_to timestamptz := (p_to + 1)::timestamptz;  -- inclusive end date
  v_candidates boolean;
  v_fill jsonb;
  v_hires jsonb := '[]'::jsonb;
  v_offers jsonb;
  v_activity jsonb := '[]'::jsonb;
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
  v_candidates := app.has_capability(p_company_id, 'candidates.view');

  with hires as (
    select a.job_id, h.hired_at
    from app.report_hires(p_company_id) h
    join public.applications a on a.id = h.application_id
    join public.jobs j on j.id = a.job_id
    where h.hired_at >= j.opened_at
  ),
  jobs as (
    select j.id, j.title, j.status, j.opened_at,
           r.target_start_date,
           coalesce(r.headcount, 1) as headcount,
           (select count(*) from public.applications a where a.job_id = j.id) as applicants,
           (select count(*) from hires h where h.job_id = j.id) as hires,
           (select h.hired_at from hires h where h.job_id = j.id
            order by h.hired_at offset coalesce(r.headcount, 1) - 1 limit 1) as filled_at
    from public.jobs j
    left join public.hiring_requests r on r.id = j.hiring_request_id
    where j.company_id = p_company_id and j.opened_at is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', f.id, 'title', f.title, 'status', f.status,
           'opened_on', f.opened_at::date,
           'target_start_date', f.target_start_date,
           'headcount', f.headcount, 'applicants', f.applicants, 'hires', f.hires,
           'filled_on', f.filled_at::date,
           'days', greatest(0, (coalesce(f.filled_at, now())::date - f.opened_at::date)),
           'late_days', case when f.target_start_date is null then 0
                             else greatest(0, coalesce(f.filled_at, now())::date - f.target_start_date) end
         ) order by (f.filled_at is not null), coalesce(f.filled_at, now()) - f.opened_at desc, f.title), '[]'::jsonb)
  into v_fill
  from jobs f
  where (f.status in ('open', 'on_hold') and f.filled_at is null)
     or (f.filled_at >= v_from and f.filled_at < v_to);

  if v_candidates then
    select coalesce(jsonb_agg(jsonb_build_object(
             'application_id', a.id, 'candidate', c.full_name,
             'job_id', j.id, 'job', j.title,
             'received_on', a.received_at::date, 'hired_on', h.hired_at::date,
             'days', greatest(0, h.hired_at::date - a.received_at::date)
           ) order by h.hired_at desc), '[]'::jsonb)
    into v_hires
    from app.report_hires(p_company_id) h
    join public.applications a on a.id = h.application_id
    join public.candidates c on c.id = a.candidate_id
    join public.jobs j on j.id = a.job_id
    where h.hired_at >= v_from and h.hired_at < v_to;

    select coalesce(jsonb_agg(row_to_json(e)::jsonb order by e.at desc), '[]'::jsonb)
    into v_activity
    from (
      select ev.created_at as at, a.id as application_id, c.full_name as candidate,
             j.id as job_id, j.title as job,
             ev.from_stage_key as from_stage, ev.to_stage_key as to_stage,
             p.full_name as actor
      from public.application_events ev
      join public.applications a on a.id = ev.application_id
      join public.candidates c on c.id = a.candidate_id
      join public.jobs j on j.id = a.job_id
      left join public.people p on p.id = ev.actor_id
      where a.company_id = p_company_id
        and ev.kind = 'stage_change'
        and ev.created_at >= v_from and ev.created_at < v_to
      order by ev.created_at desc
      limit 60
    ) e;
  end if;

  select jsonb_build_object(
    'extended', count(*) filter (where o.status = 'extended'),
    'accepted', count(*) filter (where o.status = 'accepted'),
    'declined', count(*) filter (where o.status = 'declined')
  ) into v_offers
  from public.offers o
  where o.company_id = p_company_id
    and o.created_at >= v_from and o.created_at < v_to;

  return jsonb_build_object(
    'company_id', p_company_id,
    'from', p_from, 'to', p_to,
    'can_see_candidates', v_candidates,
    'fill', v_fill, 'hires', v_hires, 'offers', v_offers, 'activity', v_activity
  );
end $$;

-- ------------------------------------------------------------------ grants
revoke all on function app.jobs_opening_stamp() from public;
revoke all on function public.recruitment_insights(uuid, date, date) from public, anon;
grant execute on function public.recruitment_insights(uuid, date, date) to authenticated;

commit;
