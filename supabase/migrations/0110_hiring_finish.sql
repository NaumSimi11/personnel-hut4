-- 0110_hiring_finish.sql
-- The remaining steps of the Hiring Module user flows (11 Nov 2026):
--   * 5.x  scheduling an interview notifies everyone on the panel.
--   * 6.1  offers drafted from a template: bonus, benefits, conditions, notes.
--   * 7.5  when the last position is filled, the recruiter decides on each
--          remaining application: reject (the rejection email goes, reason
--          code "position filled"), keep in the talent pool, or keep on hold.
--          Nothing is sent until they choose.
--   * 7.6  HR or the manager confirms the first day: pre-start becomes active.
--   * 8.1  a request on hold reminds its requester on its review date.
--   * 10.4 an approved request can still change its start date and hiring
--          manager freely; a change to title, reason, headcount or salary
--          band sends it back through its approval route.
--   * 10.8 an approval step waiting too long reminds its approvers, then
--          tells the company's HR contact.
-- Time limits come from hiring_settings (0109).

begin;

-- ------------------------------------------------- 5.x interview scheduled
create or replace function app.notify_interview_panel() returns trigger
language plpgsql security definer set search_path = public as $$
declare v record;
begin
  if current_setting('app.bulk_import', true) = 'on' or new.person_id = app.current_person_id() then return new; end if;
  select i.id, i.company_id, i.application_id, i.scheduled_at, i.kind, c.full_name, j.title into v
    from public.interviews i
    join public.applications a on a.id = i.application_id
    join public.candidates c on c.id = a.candidate_id
    left join public.jobs j on j.id = a.job_id
   where i.id = new.interview_id and i.provider is null;
  if not found then return new; end if;
  perform app.notify(new.person_id, v.company_id, 'interview.scheduled',
    'Interview: ' || coalesce(v.full_name, 'candidate') || ' · ' || to_char(v.scheduled_at at time zone 'Europe/Skopje', 'DD Mon HH24:MI'),
    coalesce(v.title, 'Role') || ' · ' || replace(v.kind, '_', ' ') || ' interview · you are on the panel',
    '/hiring/applications/' || v.application_id, 'interview', v.id,
    'interview.scheduled:' || v.id || ':' || new.person_id);
  return new;
end $$;
create trigger t9_notify after insert on public.interview_panel
  for each row execute function app.notify_interview_panel();

-- ------------------------------------------------------ 6.1 offer templates
create table public.offer_templates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  bonus text check (bonus is null or length(bonus) <= 300),
  benefits text check (benefits is null or length(benefits) <= 2000),
  conditions text check (conditions is null or length(conditions) <= 2000),
  notes text check (notes is null or length(notes) <= 2000),
  unique nulls not distinct (company_id, name)
);
alter table public.offer_templates enable row level security;
create policy sel on public.offer_templates for select to authenticated using (true);
create policy write on public.offer_templates for all to authenticated
  using (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')))
  with check (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')));
grant select, insert, update, delete on public.offer_templates to authenticated;
grant all on public.offer_templates to service_role;
insert into public.offer_templates (company_id, name, bonus, benefits, conditions) values
  (null, 'Standard', null, 'Private health insurance · 21 days of annual leave',
   'Subject to a signed employment contract and the usual pre-employment checks.');

-- The candidate's page and email carry the template's parts (0106 + these).
-- The offer's notes are internal (the form says so) and no longer reach the candidate.
create or replace function public.offer_for_candidate(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'status', o.status, 'candidate', c.full_name, 'job', coalesce(j.title, 'the role'), 'company', co.name,
    'salary', o.terms->>'salary', 'currency', o.terms->>'currency', 'pay_basis', pb.label,
    'employment_type', et.label, 'start_date', o.terms->>'start_date',
    'bonus', o.terms->>'bonus', 'benefits', o.terms->>'benefits', 'conditions', o.terms->>'conditions',
    'expires_on', o.expires_on, 'expired', o.expires_on is not null and o.expires_on < current_date,
    'answered_at', o.answered_by_candidate_at)
    from public.offers o
    join public.applications a on a.id = o.application_id
    join public.candidates c on c.id = a.candidate_id
    join public.companies co on co.id = a.company_id
    left join public.jobs j on j.id = a.job_id
    left join public.pay_bases pb on pb.key = o.terms->>'pay_basis'
    left join public.employment_types et on et.key = o.terms->>'employment_type'
   where p_token is not null and length(p_token) = 64 and o.candidate_token = p_token
     and o.status in ('extended', 'accepted', 'declined')
$$;
revoke execute on function public.offer_for_candidate(text) from public, anon, authenticated;
grant execute on function public.offer_for_candidate(text) to service_role;

create or replace function app.offer_email_data(p_offer_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'candidate', c.full_name, 'job', coalesce(j.title, 'the role'), 'company', co.name,
    'token', o.candidate_token, 'salary', o.terms->>'salary', 'currency', o.terms->>'currency',
    'start_date', o.terms->>'start_date', 'expires_on', o.expires_on, 'bonus', o.terms->>'bonus')
    from public.offers o
    join public.applications a on a.id = o.application_id
    join public.candidates c on c.id = a.candidate_id
    join public.companies co on co.id = a.company_id
    left join public.jobs j on j.id = a.job_id
   where o.id = p_offer_id
$$;

-- --------------------------------------- 7.5 the applications left over
alter table public.applications
  add column after_fill text check (after_fill in ('rejected', 'pool', 'hold'));

create or replace function public.decide_after_fill(p_application_ids uuid[], p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_id uuid;
  v_app record;
  v_status text;
  v_n int := 0;
  v_emailed int := 0;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_action not in ('rejected', 'pool', 'hold') then
    raise exception 'Reject, keep in the talent pool, or keep on hold.' using errcode = '22023';
  end if;
  for v_id in select distinct u.id from unnest(coalesce(p_application_ids, '{}')) u(id) loop
    select a.id, a.company_id, a.stage_key, a.sub_status_key, a.closed_at, a.closed_reason, a.after_fill, j.status as job_status
      into v_app
      from public.applications a join public.jobs j on j.id = a.job_id
     where a.id = v_id for update of a;
    if not found then
      raise exception 'That application no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_app.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" here.' using errcode = '42501';
    end if;
    if v_app.job_status <> 'filled' or v_app.closed_at is null then
      raise exception 'Only applications left open when the job filled are decided here.' using errcode = '22023';
    end if;
    if v_app.after_fill = 'rejected' then continue; end if;

    insert into public.application_events (application_id, actor_id, kind, body, from_stage_key, to_stage_key, from_sub_status_key, to_sub_status_key)
    values (v_app.id, v_me, 'status_change',
            case p_action when 'rejected' then 'Rejected after the position was filled'
                          when 'pool' then 'Kept in the talent pool for future roles'
                          else 'Kept on hold in case the position reopens' end,
            v_app.stage_key, v_app.stage_key, v_app.sub_status_key, v_app.sub_status_key);

    if p_action = 'rejected' then
      v_status := case when v_app.stage_key = 'screening' then 'unqualified' else 'rejected_by_hr' end;
      perform set_config('app.bulk_import', 'on', true);
      update public.applications
         set stage_key = (select stage_key from public.application_sub_statuses where key = v_status),
             sub_status_key = v_status, reason_code = 'position_filled',
             rejected_reason = coalesce(nullif(rejected_reason, ''), 'Position filled'), after_fill = 'rejected'
       where id = v_app.id;
      perform set_config('app.bulk_import', 'off', true);
      if app.queue_candidate_email(v_app.id, 'rejected', v_me) = 'queued' then v_emailed := v_emailed + 1; end if;
    else
      update public.applications set after_fill = p_action where id = v_app.id;
    end if;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('decided', v_n, 'emailed', v_emailed);
end $$;
grant execute on function public.decide_after_fill(uuid[], text) to authenticated;

-- ------------------------------------------------------ 7.6 the first day
create or replace function public.confirm_first_day(p_period_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_p public.employment_periods;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_p from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'That employment no longer exists.' using errcode = '22023';
  end if;
  if not (app.has_capability(v_p.company_id, 'employment.edit') or v_p.manager_id = app.current_person_id()) then
    raise exception 'HR or the manager confirms the first day.' using errcode = '42501';
  end if;
  if v_p.status <> 'pre_start' then
    raise exception 'This employment is already %.', replace(v_p.status, '_', ' ') using errcode = '22023';
  end if;
  if v_p.start_date > current_date then
    raise exception 'The first day is %; confirm it on the day.', to_char(v_p.start_date, 'DD Mon YYYY') using errcode = '22023';
  end if;
  update public.employment_periods set status = 'active' where id = v_p.id;
  return jsonb_build_object('status', 'active');
end $$;
grant execute on function public.confirm_first_day(uuid) to authenticated;

-- ---------------------------------------- 10.4 changes after approval
-- The 0101 gate, with the content lock lifted for the lifecycle doors.
create or replace function app.gate_hiring_request_transitions() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prev text;
  me uuid := app.current_person_id();
  mine boolean;
  v_lifecycle boolean := coalesce(current_setting('app.request_lifecycle', true), '') = 'on';
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then prev := old.status; end if;
  mine := new.requested_by is not distinct from me;

  if new.status is distinct from prev
     and (new.status in ('on_hold', 'filled') or prev in ('on_hold', 'filled'))
     and not v_lifecycle then
    raise exception 'Use Hold, Resume or Cancel on the request for that.' using errcode = '42501';
  end if;

  if new.status in ('approved', 'rejected', 'changes_requested') and new.status is distinct from prev
     and not v_lifecycle then
    if not app.has_capability(new.company_id, 'jobs.approve') then
      raise exception 'Deciding a hiring request requires jobs.approve'
        using errcode = '42501';
    end if;
    if mine and not app.is_admin() then
      raise exception 'Requesters cannot decide their own hiring request'
        using errcode = '42501';
    end if;
    if new.status in ('changes_requested', 'rejected') and nullif(trim(coalesce(new.change_reason, '')), '') is null then
      raise exception 'Say what needs to change, or why the request is rejected.';
    end if;
    new.decided_by := me;
    new.decided_at := now();
  end if;

  if tg_op = 'UPDATE' and new.status = 'submitted' and prev = 'changes_requested' then
    if not (mine or app.has_capability(new.company_id, 'jobs.edit') or app.is_admin()) then
      raise exception 'Only the requester can revise and resubmit this request'
        using errcode = '42501';
    end if;
    new.decided_by := null;
    new.decided_at := null;
    new.change_reason := null;
  end if;

  if tg_op = 'UPDATE' and prev not in ('draft', 'changes_requested') and not v_lifecycle
     and (new.title, new.reason, new.headcount, new.target_start_date, new.hiring_manager_id, new.budget)
         is distinct from (old.title, old.reason, old.headcount, old.target_start_date, old.hiring_manager_id, old.budget) then
    raise exception 'A submitted request cannot be edited; ask for changes first.';
  end if;
  return new;
end $$;

create or replace function public.amend_hiring_request(p_request_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req public.hiring_requests := app.request_for_lifecycle(p_request_id);
  v_title text := coalesce(nullif(trim(p->>'title'), ''), v_req.title);
  v_reason text := case when p ? 'reason' then nullif(trim(p->>'reason'), '') else v_req.reason end;
  v_headcount int := coalesce(nullif(p->>'headcount', '')::int, v_req.headcount);
  v_start date := case when p ? 'target_start_date' then nullif(p->>'target_start_date', '')::date else v_req.target_start_date end;
  v_hm uuid := case when p ? 'hiring_manager_id' then nullif(p->>'hiring_manager_id', '')::uuid else v_req.hiring_manager_id end;
  v_budget jsonb := case when p ? 'budget' then nullif(p->'budget', 'null'::jsonb) else v_req.budget end;
  v_major boolean;
begin
  if v_req.status <> 'approved' then
    raise exception 'Only an approved request is amended here.' using errcode = '22023';
  end if;
  if v_headcount < 1 then
    raise exception 'Headcount must be at least 1.' using errcode = '22023';
  end if;
  v_major := (v_title, v_reason, v_headcount, v_budget) is distinct from (v_req.title, v_req.reason, v_req.headcount, v_req.budget);
  perform set_config('app.request_lifecycle', 'on', true);
  update public.hiring_requests
     set title = v_title, reason = v_reason, headcount = v_headcount, target_start_date = v_start,
         hiring_manager_id = v_hm, budget = v_budget,
         status = case when v_major then 'submitted' else status end,
         decided_by = case when v_major then null else decided_by end,
         decided_at = case when v_major then null else decided_at end
   where id = v_req.id;
  perform set_config('app.request_lifecycle', 'off', true);
  return jsonb_build_object('status', case when v_major then 'submitted' else 'approved' end, 'reapproval', v_major);
end $$;
grant execute on function public.amend_hiring_request(uuid, jsonb) to authenticated;

-- The 0104 route wiring, plus: back from Approved to Submitted is a new round.
create or replace function app.request_approval_flow() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_asked public.approval_tasks;
  v_open public.approval_tasks;
  v_lifecycle boolean := coalesce(current_setting('app.request_lifecycle', true), '') = 'on';
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.start_approval('request', new.id, new.company_id, 'request',
      exists (select 1 from public.approval_routes r where r.company_id = new.company_id and r.kind = 'request'));
    return new;
  end if;
  if new.status = 'submitted' and old.status = 'approved' then
    perform app.start_approval('request', new.id, new.company_id, 'request', true);
    return new;
  end if;
  if new.status = 'submitted' and old.status = 'changes_requested' then
    select * into v_asked from public.approval_tasks
     where subject_type = 'request' and subject_id = new.id and status = 'changes_requested'
     order by acted_at desc nulls last limit 1;
    if v_asked.id is null then
      perform app.start_approval('request', new.id, new.company_id, 'request', true);
    else
      insert into public.approval_tasks (subject_type, subject_id, company_id, round, position, label, approver_id, capability)
      values ('request', new.id, new.company_id, v_asked.round, v_asked.position, v_asked.label, v_asked.approver_id, v_asked.capability)
      returning * into v_open;
      perform app.notify_task(v_open);
    end if;
    return new;
  end if;
  if not v_lifecycle and tg_op = 'UPDATE' and old.status = 'submitted' then
    v_open := app.current_task('request', new.id);
    if v_open.id is not null then
      if new.status = 'approved' then
        update public.approval_tasks set status = 'approved', acted_by = app.current_person_id(), acted_at = now(),
               comment = 'Decided on the request'
         where subject_type = 'request' and subject_id = new.id and status = 'open';
      elsif new.status = 'changes_requested' then
        update public.approval_tasks set status = 'changes_requested', acted_by = app.current_person_id(), acted_at = now(),
               comment = new.change_reason where id = v_open.id;
      else
        update public.approval_tasks set status = 'superseded'
         where subject_type = 'request' and subject_id = new.id and status = 'open';
      end if;
    end if;
  end if;
  if new.status in ('cancelled', 'rejected') then
    update public.approval_tasks set status = 'superseded'
     where subject_type = 'request' and subject_id = new.id and status = 'open';
  end if;
  return new;
end $$;

-- ------------------------------------------------------------ the clocks
create or replace function public.run_hiring_clocks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v record;
  v_offers int := 0;
  v_first int := 0;
  v_feedback int := 0;
  v_holds int := 0;
  v_overdue int := 0;
  v_to uuid;
begin
  -- 6.4 / 8.7: offers waiting on the candidate.
  for v in
    select o.id, o.company_id, o.expires_on, o.created_by, a.id as application_id,
           c.full_name, j.title, (o.expires_on < current_date) as expired
      from public.offers o
      join public.applications a on a.id = o.application_id
      join public.candidates c on c.id = a.candidate_id
      left join public.jobs j on j.id = a.job_id
     where o.status = 'extended' and o.expires_on is not null
       and o.expires_on - app.hiring_setting(o.company_id, 'offer_warn_days') <= current_date
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

  -- 8.5: first response.
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
       and a.received_at < now() - make_interval(days => app.hiring_setting(a.company_id, 'first_response_days'))
       and a.received_at > now() - interval '30 days'
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

  -- 8.6: interview feedback.
  for v in
    select i.id, i.company_id, i.application_id, p.person_id, c.full_name, j.title, j.hiring_manager_id,
           i.scheduled_at + make_interval(mins => i.duration_minutes) as ended_at
      from public.interviews i
      join public.interview_panel p on p.interview_id = i.id
      join public.applications a on a.id = i.application_id
      join public.candidates c on c.id = a.candidate_id
      left join public.jobs j on j.id = a.job_id
     where i.status <> 'cancelled' and i.provider is null
       and i.scheduled_at + make_interval(mins => i.duration_minutes)
           < now() - make_interval(hours => app.hiring_setting(i.company_id, 'feedback_remind_hours'))
       and i.scheduled_at > now() - interval '30 days'
       and not exists (select 1 from public.scorecards s where s.interview_id = i.id and s.author_id = p.person_id)
  loop
    perform app.notify(v.person_id, v.company_id, 'interview.feedback_due',
      'Scorecard due: ' || coalesce(v.full_name, 'candidate'),
      coalesce(v.title, 'Role') || ' · the interview ended ' || to_char(v.ended_at, 'DD Mon HH24:MI'),
      '/hiring/applications/' || v.application_id, 'interview', v.id,
      'interview.feedback_due:' || v.id || ':' || v.person_id);
    if v.ended_at < now() - make_interval(hours => app.hiring_setting(v.company_id, 'feedback_escalate_hours'))
       and v.hiring_manager_id is not null and v.hiring_manager_id <> v.person_id then
      perform app.notify(v.hiring_manager_id, v.company_id, 'interview.feedback_missing',
        'Feedback missing: ' || coalesce(v.full_name, 'candidate'),
        app.person_name(v.person_id) || ' has not scored the interview of ' || to_char(v.ended_at, 'DD Mon'),
        '/hiring/applications/' || v.application_id, 'interview', v.id,
        'interview.feedback_missing:' || v.id || ':' || v.person_id);
    end if;
    v_feedback := v_feedback + 1;
  end loop;

  -- 8.1: a request on hold comes up for review.
  for v in
    select r.id, r.company_id, r.title, r.requested_by, r.hold_review_on, co.hr_contact_person_id
      from public.hiring_requests r join public.companies co on co.id = r.company_id
     where r.status = 'on_hold' and r.hold_review_on is not null and r.hold_review_on <= current_date
  loop
    for v_to in select x from (select v.requested_by as x union select v.hr_contact_person_id) s where x is not null loop
      perform app.notify(v_to, v.company_id, 'hiring.review_hold', 'Review the hold: ' || v.title,
        'On hold since before ' || to_char(v.hold_review_on, 'DD Mon YYYY') || ' · resume or cancel it',
        '/hiring', 'hiring_request', v.id, 'hiring.review_hold:' || v.id || ':' || v.hold_review_on);
    end loop;
    v_holds := v_holds + 1;
  end loop;

  -- 10.8: approval steps waiting too long.
  for v in
    select t as task, t.id, t.company_id, t.label, t.position, t.approver_id, t.capability,
           coalesce((select max(p.acted_at) from public.approval_tasks p
                      where p.subject_type = t.subject_type and p.subject_id = t.subject_id
                        and p.round = t.round and p.position < t.position), t.created_at) as waiting_since,
           co.hr_contact_person_id
      from public.approval_tasks t join public.companies co on co.id = t.company_id
     where t.status = 'open' and t.id = (app.current_task(t.subject_type, t.subject_id)).id
  loop
    if v.waiting_since < now() - make_interval(days => app.hiring_setting(v.company_id, 'approval_overdue_days')) then
      for v_to in
        select x from (select v.approver_id as x where v.approver_id is not null
                       union select h from app.approvers_or_contacts(v.company_id, v.capability) h where v.capability is not null) s
         where x is not null
      loop
        perform app.notify(v_to, v.company_id, 'approval.overdue',
          'Still waiting for your approval: ' || coalesce(app.task_subject_title(v.task), 'approval'),
          v.label || ' · waiting since ' || to_char(v.waiting_since, 'DD Mon'), '/hiring?tab=approvals',
          'approval_task', v.id, 'approval.overdue:' || v.id, true);
      end loop;
      v_overdue := v_overdue + 1;
    end if;
    if v.waiting_since < now() - make_interval(days => app.hiring_setting(v.company_id, 'approval_escalate_days'))
       and v.hr_contact_person_id is not null then
      perform app.notify(v.hr_contact_person_id, v.company_id, 'approval.escalated',
        'Approval stuck: ' || coalesce(app.task_subject_title(v.task), 'approval'),
        v.label || ' · step ' || v.position || ' · waiting since ' || to_char(v.waiting_since, 'DD Mon'),
        '/hiring?tab=approvals', 'approval_task', v.id, 'approval.escalated:' || v.id, true);
    end if;
  end loop;

  return jsonb_build_object('offers', v_offers, 'first_response', v_first, 'feedback', v_feedback,
                            'holds', v_holds, 'overdue_approvals', v_overdue);
end $$;
revoke execute on function public.run_hiring_clocks() from public, anon, authenticated;
grant execute on function public.run_hiring_clocks() to service_role;

commit;
