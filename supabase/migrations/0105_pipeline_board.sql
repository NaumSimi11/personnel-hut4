-- 0105_pipeline_board.sql
-- The spec's pipeline on top of HR's statuses (Hiring Module user flows,
-- 11 Nov 2026: 3.3, 5.1–5.7, screen 9.8).
--
-- The spec has nine stages; production has four, with HR's column-T statuses
-- inside them (0098). Default chosen: keep the four stages (no data moves),
-- and give the spec's extra stages a home as statuses:
--   * applied      (Screening) — where a careers-page application lands (5.1)
--   * shortlisted  (Screening) — the recruiter passes the CV to the hiring
--                                manager (5.2 -> 5.3); the HM's call follows
-- Technical test, Interview 1 (HR) and Final interview are the Interview
-- statuses interview_task, interview_hr and interview_stakeholders already.
-- A job may switch those three off before it opens (3.3): they are hidden on
-- its board and refused for its applications, and the choice locks once the
-- job is open.

begin;

insert into public.application_sub_statuses (key, stage_key, label, sort_order, outcome) values
  ('applied', 'screening', 'applied', 5, 'open'),
  ('shortlisted', 'screening', 'shortlisted', 12, 'open');

-- Where a new application starts: the careers page lands at Applied; every
-- other source at Screening starts Sourced, as before.
create or replace function app.default_sub_status(p_stage text, p_source_key text) returns text
language sql stable security definer set search_path = public as $$
  select s.key from public.application_sub_statuses s
   where s.stage_key = p_stage and s.archived_at is null
   order by coalesce(p_stage = 'screening' and p_source_key = 'careers_page' and s.key = 'applied', false) desc,
            (s.key = 'sourced') desc, s.sort_order, s.key
   limit 1
$$;

-- -------------------------------------------- optional stages per job (3.3)
alter table public.jobs add column skip_statuses text[] not null default '{}'
  check (skip_statuses <@ array['interview_task', 'interview_hr', 'interview_stakeholders']::text[]);

create or replace function app.guard_job_pipeline() returns trigger
language plpgsql as $$
begin
  if new.skip_statuses is distinct from old.skip_statuses and old.status not in ('draft', 'ready') then
    raise exception 'The pipeline is locked once the job is open.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger t2_pipeline_lock before update of skip_statuses on public.jobs
  for each row execute function app.guard_job_pipeline();

create or replace function app.guard_skipped_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if tg_op = 'UPDATE' and new.sub_status_key is not distinct from old.sub_status_key then return new; end if;
  if exists (select 1 from public.jobs j where j.id = new.job_id and new.sub_status_key = any (j.skip_statuses)) then
    raise exception 'This job skips "%".', new.sub_status_key using errcode = '22023';
  end if;
  return new;
end $$;
create trigger t4_skipped_status before insert or update of sub_status_key on public.applications
  for each row execute function app.guard_skipped_status();

-- -------------------------------------------- first response (0103) follows
create or replace function public.run_hiring_clocks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_offer_warn_days constant int := 2;
  c_first_response_days constant int := 3;
  c_lookback_days constant int := 30;
  v record;
  v_offers int := 0;
  v_first int := 0;
  v_to uuid;
begin
  for v in
    select o.id, o.company_id, o.expires_on, o.created_by, a.id as application_id,
           c.full_name, j.title, (o.expires_on < current_date) as expired
      from public.offers o
      join public.applications a on a.id = o.application_id
      join public.candidates c on c.id = a.candidate_id
      left join public.jobs j on j.id = a.job_id
     where o.status = 'extended' and o.expires_on is not null
       and o.expires_on - c_offer_warn_days <= current_date
       and o.created_by is not null
  loop
    perform app.notify(v.created_by, v.company_id,
      case when v.expired then 'offer.expired' else 'offer.expiring' end,
      case when v.expired then 'Offer expired: ' else 'Offer expires soon: ' end || coalesce(v.full_name, 'Candidate'),
      coalesce(v.title, 'Role') || ' · ' || case when v.expired then 'expired ' else 'expires ' end
        || to_char(v.expires_on, 'DD Mon YYYY') || ' · no answer recorded',
      '/hiring/applications/' || v.application_id, 'offer', v.id,
      case when v.expired then 'offer.expired:' else 'offer.expiring:' end || v.id || ':' || v.expires_on);
    v_offers := v_offers + 1;
  end loop;

  for v in
    select a.id, a.company_id, a.owner_id, a.received_at, c.full_name, j.title, co.hr_contact_person_id
      from public.applications a
      join public.candidates c on c.id = a.candidate_id
      join public.companies co on co.id = a.company_id
      left join public.jobs j on j.id = a.job_id
     where a.source_key = 'careers_page'
       and a.provider_ref is null
       and a.stage_key = 'screening' and a.sub_status_key in ('applied', 'sourced')
       and a.in_play and a.closed_at is null
       and a.received_at < now() - make_interval(days => c_first_response_days)
       and a.received_at > now() - make_interval(days => c_lookback_days)
  loop
    v_to := coalesce(v.owner_id, v.hr_contact_person_id);
    continue when v_to is null;
    perform app.notify(v_to, v.company_id, 'application.first_response',
      'No reply yet: ' || coalesce(v.full_name, 'Candidate'),
      coalesce(v.title, 'Role') || ' · applied ' || to_char(v.received_at, 'DD Mon') || ' · nobody has reached out',
      '/hiring/applications/' || v.id, 'application', v.id,
      'application.first_response:' || v.id);
    v_first := v_first + 1;
  end loop;

  return jsonb_build_object('offers', v_offers, 'first_response', v_first);
end $$;
revoke execute on function public.run_hiring_clocks() from public, anon, authenticated;
grant execute on function public.run_hiring_clocks() to service_role;

commit;
