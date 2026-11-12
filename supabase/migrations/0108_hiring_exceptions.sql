-- 0108_hiring_exceptions.sql
-- The rest of the exceptions (Hiring Module user flows, 11 Nov 2026: 4.3,
-- section 4 "same person, two channels", 8.4, 8.6).
--
--   * Did Not Start (8.4): HR marks a pre-start employment Did Not Start
--     with a reason. Its onboarding plan is cancelled, IT and payroll hear,
--     the hire's application is withdrawn ("Did not start"), the job reopens
--     if it was filled, and the recruiter is told how many runners-up are
--     still in play.
--   * Interview feedback (8.6): 24 hours after an interview ends, each panel
--     member who has not scored is reminded; at 48 hours the job's hiring
--     manager is told who is missing.
--   * Former employees and earlier applications (4.3): candidate_flags()
--     says whether the candidate's email belongs to someone who worked here,
--     and how many other applications they have.
--   * Source credit (section 4): an application from the same person within
--     90 days of an earlier one credits the earliest source.

begin;

-- ------------------------------------------------------------ Did Not Start
insert into public.employment_statuses (key, label, counts_as_employed, sort_order)
values ('did_not_start', 'Did not start', false, 45)
on conflict (key) do nothing;

create or replace function public.mark_did_not_start(p_period_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_reason text := trim(coalesce(p_reason, ''));
  v_p public.employment_periods;
  v_app public.applications;
  v_name text;
  v_runners int := 0;
  v_to uuid;
  v_job_status text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_p from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'That employment no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_p.company_id, 'employment.edit') then
    raise exception 'You need "Edit employment information" in this company.' using errcode = '42501';
  end if;
  if v_p.status <> 'pre_start' then
    raise exception 'Only someone who has not started yet can be marked Did not start.' using errcode = '22023';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Say why the hire did not start (withdrew, did not show up, offer rescinded…).' using errcode = '22023';
  end if;
  select full_name into v_name from public.people where id = v_p.person_id;

  update public.employment_periods set status = 'did_not_start', end_date = start_date where id = v_p.id;
  update public.plan_tasks set status = 'skipped'
   where status in ('open', 'blocked')
     and plan_id in (select id from public.plans where employment_period_id = v_p.id and kind = 'onboarding');
  update public.plans set status = 'cancelled'
   where employment_period_id = v_p.id and kind = 'onboarding' and status = 'in_progress';

  for v_to in
    select distinct x from (
      select h as x from app.capability_holders(v_p.company_id, 'it.view') h
      union select h from app.capability_holders(v_p.company_id, 'payroll.individual') h
    ) s where x is not null and x <> v_me
  loop
    perform app.notify(v_to, v_p.company_id, 'hire.did_not_start', 'Did not start: ' || coalesce(v_name, 'new hire'),
      v_p.job_title || ' · was to start ' || to_char(v_p.start_date, 'DD Mon YYYY') || ' · ' || v_reason,
      '/people/' || v_p.person_id, 'employment_period', v_p.id, 'hire.did_not_start:' || v_p.id, true);
  end loop;

  select * into v_app from public.applications where employment_period_id = v_p.id limit 1;
  if found then
    insert into public.application_events (application_id, actor_id, kind, body, from_stage_key, to_stage_key)
    values (v_app.id, v_me, 'status_change', 'Did not start: ' || v_reason, v_app.stage_key, v_app.stage_key);
    perform set_config('app.bulk_import', 'on', true);
    update public.applications set stage_key = 'interview', sub_status_key = 'withdrawn',
           withdrawn_reason = 'Did not start: ' || v_reason, employment_period_id = null
     where id = v_app.id;
    perform set_config('app.bulk_import', 'off', true);
    select status into v_job_status from public.jobs where id = v_app.job_id;
    if v_job_status = 'filled' then
      update public.jobs set status = 'open' where id = v_app.job_id;
    end if;
    select count(*) into v_runners from public.applications
     where job_id = v_app.job_id and in_play and id <> v_app.id;
    v_to := coalesce(v_app.owner_id, (select hiring_manager_id from public.jobs where id = v_app.job_id));
    if v_to is not null and v_to <> v_me then
      perform app.notify(v_to, v_p.company_id, 'hire.reopened', 'Position reopened: ' || v_p.job_title,
        coalesce(v_name, 'The hire') || ' did not start · ' || v_runners || ' candidate(s) still in play',
        '/hiring/jobs/' || v_app.job_id, 'job', v_app.job_id, 'hire.reopened:' || v_p.id);
    end if;
  end if;
  return jsonb_build_object('status', 'did_not_start', 'runners_up', v_runners, 'job_id', v_app.job_id);
end $$;
grant execute on function public.mark_did_not_start(uuid, text) to authenticated;

-- ------------------------------------------------- former employees (4.3)
create or replace function public.candidate_flags(p_candidate_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'former_employee', exists (
      select 1 from public.people p
        join public.employment_periods ep on ep.person_id = p.id and ep.status = 'former'
       where p.id = c.person_id
          or (c.email is not null and (lower(p.work_email) = lower(c.email) or lower(p.personal_email) = lower(c.email)))),
    'other_applications', (select count(*) from public.applications a where a.candidate_id = c.id) - 1)
    from public.candidates c
   where c.id = p_candidate_id and app.can_view_candidate(c.id)
$$;
grant execute on function public.candidate_flags(uuid) to authenticated;

-- ------------------------------------------------------------ source credit
alter table public.applications add column credited_source_key text references public.candidate_sources(key);

create or replace function app.credit_earliest_source() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c_credit_days constant int := 90;
begin
  select a.source_key into new.credited_source_key
    from public.applications a
   where a.candidate_id = new.candidate_id and a.id <> new.id
     and a.received_at > coalesce(new.received_at, now()) - make_interval(days => c_credit_days)
     and a.source_key is not null
   order by a.received_at
   limit 1;
  new.credited_source_key := coalesce(new.credited_source_key, new.source_key);
  return new;
end $$;
create trigger t2_credit_source before insert on public.applications
  for each row execute function app.credit_earliest_source();

alter table public.applications disable trigger user;
update public.applications set credited_source_key = source_key where credited_source_key is null;
alter table public.applications enable trigger user;

-- ----------------------------------------------- the clocks, once more (8.6)
create or replace function public.run_hiring_clocks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_offer_warn_days constant int := 2;
  c_first_response_days constant int := 3;
  c_lookback_days constant int := 30;
  c_feedback_remind_hours constant int := 24;
  c_feedback_escalate_hours constant int := 48;
  v record;
  v_offers int := 0;
  v_first int := 0;
  v_feedback int := 0;
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
  loop
    if not v.expired and v.created_by is not null then
      perform app.queue_offer_email(v.id, 'offer_reminder');
    end if;
    if v.created_by is not null then
      perform app.notify(v.created_by, v.company_id,
        case when v.expired then 'offer.expired' else 'offer.expiring' end,
        case when v.expired then 'Offer expired: ' else 'Offer expires soon: ' end || coalesce(v.full_name, 'Candidate'),
        coalesce(v.title, 'Role') || ' · ' || case when v.expired then 'expired ' else 'expires ' end
          || to_char(v.expires_on, 'DD Mon YYYY') || ' · no answer recorded',
        '/hiring/applications/' || v.application_id, 'offer', v.id,
        case when v.expired then 'offer.expired:' else 'offer.expiring:' end || v.id || ':' || v.expires_on);
    end if;
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

  -- 8.6: panel members who have not scored an interview that ended.
  for v in
    select i.id, i.company_id, i.application_id, p.person_id, c.full_name, j.title, j.hiring_manager_id,
           i.scheduled_at + make_interval(mins => i.duration_minutes) as ended_at
      from public.interviews i
      join public.interview_panel p on p.interview_id = i.id
      join public.applications a on a.id = i.application_id
      join public.candidates c on c.id = a.candidate_id
      left join public.jobs j on j.id = a.job_id
     where i.status <> 'cancelled' and i.provider is null
       and i.scheduled_at + make_interval(mins => i.duration_minutes) < now() - make_interval(hours => c_feedback_remind_hours)
       and i.scheduled_at > now() - interval '30 days'
       and not exists (select 1 from public.scorecards s where s.interview_id = i.id and s.author_id = p.person_id)
  loop
    perform app.notify(v.person_id, v.company_id, 'interview.feedback_due',
      'Scorecard due: ' || coalesce(v.full_name, 'candidate'),
      coalesce(v.title, 'Role') || ' · the interview ended ' || to_char(v.ended_at, 'DD Mon HH24:MI'),
      '/hiring/applications/' || v.application_id, 'interview', v.id,
      'interview.feedback_due:' || v.id || ':' || v.person_id);
    if v.ended_at < now() - make_interval(hours => c_feedback_escalate_hours) and v.hiring_manager_id is not null
       and v.hiring_manager_id <> v.person_id then
      perform app.notify(v.hiring_manager_id, v.company_id, 'interview.feedback_missing',
        'Feedback missing: ' || coalesce(v.full_name, 'candidate'),
        app.person_name(v.person_id) || ' has not scored the interview of ' || to_char(v.ended_at, 'DD Mon'),
        '/hiring/applications/' || v.application_id, 'interview', v.id,
        'interview.feedback_missing:' || v.id || ':' || v.person_id);
    end if;
    v_feedback := v_feedback + 1;
  end loop;

  return jsonb_build_object('offers', v_offers, 'first_response', v_first, 'feedback', v_feedback);
end $$;
revoke execute on function public.run_hiring_clocks() from public, anon, authenticated;
grant execute on function public.run_hiring_clocks() to service_role;

commit;
