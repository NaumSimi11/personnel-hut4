-- 0104_approval_routes.sql
-- Approval routes for hiring requests and offers (Hiring Module user flows,
-- 11 Nov 2026: 1.3, 1.4, 2.1–2.3, 6.2, 6.3; screen 9.4 My approvals).
--
-- The spec leaves the route open (10.1, 10.2). The defaults, until HR sets a
-- route per company under Hiring -> Approval routes:
--   * request ............ one step: anyone with jobs.approve (today's rule)
--   * offer, inside band . one step: HR (offer.approve)
--   * offer, outside band  HR (offer.approve), then Finance (salary.view),
--                          then the company's director (or jobs.approve when
--                          no director is set)
-- "Inside band": the request behind the job has a salary band and the offer's
-- salary is within it, in the same currency. No band -> inside (HR only),
-- shown on the offer, so jobs without a request (all of Zoho's) still move.
--
-- One engine for both: approval_tasks, one row per step per round. The
-- current step is the lowest open position of the latest round. A step names
-- a person or a capability; a named person on approved leave today is covered
-- by their delegate. Requests: approve / request changes / reject, and a
-- resubmission restarts at the step that asked (2.3). Offers: approve, or
-- send back to draft with a comment (10.6 default: an approver rejecting an
-- offer sends it back to its author); the next submission is a new round.

begin;

-- --------------------------------------------------------------- routes
create table public.approval_routes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  kind text not null check (kind in ('request', 'offer_in_band', 'offer_out_of_band')),
  position int not null check (position between 1 and 20),
  label text not null check (length(trim(label)) between 1 and 80),
  approver_id uuid references public.people(id),
  capability text references public.capabilities(key),
  check ((approver_id is null) <> (capability is null)),
  unique (company_id, kind, position)
);
alter table public.approval_routes enable row level security;
create policy sel on public.approval_routes for select to authenticated
  using (app.has_capability(company_id, 'jobs.view') or app.has_capability(company_id, 'candidates.view'));
create policy admin_write on public.approval_routes for all to authenticated
  using (app.is_admin() or app.has_capability(company_id, 'access.manage'))
  with check (app.is_admin() or app.has_capability(company_id, 'access.manage'));
grant select, insert, update, delete on public.approval_routes to authenticated;
grant all on public.approval_routes to service_role;
create trigger audit after insert or update or delete on public.approval_routes
  for each row execute function app.audit();

-- Who covers my approvals while I am away. One delegate per person.
create table public.approval_delegates (
  person_id uuid primary key references public.people(id) on delete cascade,
  delegate_id uuid not null references public.people(id) on delete cascade,
  updated_at timestamptz not null default now(),
  check (person_id <> delegate_id)
);
alter table public.approval_delegates enable row level security;
create policy sel on public.approval_delegates for select to authenticated
  using (person_id = app.current_person_id() or delegate_id = app.current_person_id() or app.is_admin());
create policy own_write on public.approval_delegates for all to authenticated
  using (person_id = app.current_person_id() or app.is_admin())
  with check (person_id = app.current_person_id() or app.is_admin());
grant select, insert, update, delete on public.approval_delegates to authenticated;
grant all on public.approval_delegates to service_role;

-- ---------------------------------------------------------------- tasks
create table public.approval_tasks (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('request', 'offer')),
  subject_id uuid not null,
  company_id uuid not null references public.companies(id) on delete cascade,
  round int not null,
  position int not null,
  label text not null,
  approver_id uuid references public.people(id),
  capability text,
  status text not null default 'open' check (status in ('open', 'approved', 'changes_requested', 'rejected', 'superseded')),
  comment text,
  acted_by uuid references public.people(id),
  acted_at timestamptz,
  created_at timestamptz not null default now()
);
create index approval_tasks_subject_idx on public.approval_tasks (subject_type, subject_id, round, position);
create index approval_tasks_open_idx on public.approval_tasks (company_id) where status = 'open';

alter table public.approval_tasks enable row level security;
create policy sel on public.approval_tasks for select to authenticated
  using (approver_id = app.current_person_id()
         or app.has_capability(company_id, 'jobs.view')
         or app.has_capability(company_id, 'candidates.view')
         or (subject_type = 'request' and exists (select 1 from public.hiring_requests r
                                                   where r.id = subject_id and r.requested_by = app.current_person_id())));
grant select on public.approval_tasks to authenticated;
grant all on public.approval_tasks to service_role;

alter table public.offers
  add column in_band boolean,
  add column band_note text,
  add column returned_reason text;

-- -------------------------------------------------------------- helpers
create or replace function app.route_steps(p_company uuid, p_kind text)
returns table (step_position int, step_label text, step_approver uuid, step_capability text)
language plpgsql stable security definer set search_path = public as $$
declare v_director uuid;
begin
  if exists (select 1 from public.approval_routes r where r.company_id = p_company and r.kind = p_kind) then
    return query select r.position, r.label, r.approver_id, r.capability
                   from public.approval_routes r where r.company_id = p_company and r.kind = p_kind
                  order by r.position;
    return;
  end if;
  if p_kind = 'request' then
    return query select 1, 'Hiring approver'::text, null::uuid, 'jobs.approve'::text;
  elsif p_kind = 'offer_in_band' then
    return query select 1, 'HR'::text, null::uuid, 'offer.approve'::text;
  else
    select director_person_id into v_director from public.companies where id = p_company;
    return query values (1, 'HR'::text, null::uuid, 'offer.approve'::text),
                        (2, 'Finance'::text, null::uuid, 'salary.view'::text),
                        (3, 'Director'::text, v_director, case when v_director is null then 'jobs.approve' end);
  end if;
end $$;

create or replace function app.is_absent(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leave_requests l
                  where l.person_id = p_person and l.status = 'approved'
                    and current_date between l.start_date and l.end_date)
$$;

/** The open task to act on now for a subject, if any. */
create or replace function app.current_task(p_type text, p_id uuid) returns public.approval_tasks
language sql stable security definer set search_path = public as $$
  select t.* from public.approval_tasks t
   where t.subject_type = p_type and t.subject_id = p_id and t.status = 'open'
     and t.round = (select max(round) from public.approval_tasks where subject_type = p_type and subject_id = p_id)
   order by t.position limit 1
$$;

create or replace function app.can_act_on_task(t public.approval_tasks) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin()
      or coalesce(t.approver_id = app.current_person_id(), false)
      or (t.approver_id is not null and app.is_absent(t.approver_id)
          and exists (select 1 from public.approval_delegates d
                       where d.person_id = t.approver_id and d.delegate_id = app.current_person_id()))
      or (t.capability is not null and app.has_capability(t.company_id, t.capability))
$$;

create or replace function app.task_subject_title(t public.approval_tasks) returns text
language sql stable security definer set search_path = public as $$
  select case t.subject_type
    when 'request' then (select 'Hiring request: ' || r.title from public.hiring_requests r where r.id = t.subject_id)
    else (select 'Offer: ' || c.full_name || coalesce(' · ' || j.title, '')
            from public.offers o join public.applications a on a.id = o.application_id
            join public.candidates c on c.id = a.candidate_id left join public.jobs j on j.id = a.job_id
           where o.id = t.subject_id) end
$$;

create or replace function app.notify_task(t public.approval_tasks) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_title text := coalesce(app.task_subject_title(t), 'Approval');
  v_to uuid;
  v_exclude uuid;
begin
  if t.subject_type = 'request' then
    select requested_by into v_exclude from public.hiring_requests where id = t.subject_id;
  end if;
  for v_to in
    select x from (
      select t.approver_id as x where t.approver_id is not null
      union select d.delegate_id from public.approval_delegates d
             where t.approver_id is not null and d.person_id = t.approver_id and app.is_absent(t.approver_id)
      union select h from app.approvers_or_contacts(t.company_id, t.capability) h where t.capability is not null
    ) s where x is not null and x is distinct from v_exclude
  loop
    perform app.notify(v_to, t.company_id, 'approval.task', 'Approval needed: ' || v_title,
      t.label || ' · step ' || t.position, '/hiring?tab=approvals', 'approval_task', t.id,
      'approval.task:' || t.id, true);
  end loop;
end $$;

/** A new round of tasks for a subject; earlier open ones are superseded. */
create or replace function app.start_approval(p_type text, p_id uuid, p_company uuid, p_kind text, p_notify_first boolean default true)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_round int;
  v_first public.approval_tasks;
begin
  update public.approval_tasks set status = 'superseded'
   where subject_type = p_type and subject_id = p_id and status = 'open';
  select coalesce(max(round), 0) + 1 into v_round from public.approval_tasks
   where subject_type = p_type and subject_id = p_id;
  insert into public.approval_tasks (subject_type, subject_id, company_id, round, position, label, approver_id, capability)
  select p_type, p_id, p_company, v_round, s.step_position, s.step_label, s.step_approver, s.step_capability
    from app.route_steps(p_company, p_kind) s;
  v_first := app.current_task(p_type, p_id);
  if p_notify_first and v_first.id is not null then perform app.notify_task(v_first); end if;
end $$;

-- ------------------------------------------------------------ the decision
create or replace function app.decide_task(p_task_id uuid, p_decision text, p_comment text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_task public.approval_tasks;
  v_current public.approval_tasks;
  v_comment text := nullif(trim(coalesce(p_comment, '')), '');
  v_req public.hiring_requests;
  v_offer public.offers;
  v_next public.approval_tasks;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_task from public.approval_tasks where id = p_task_id for update;
  if not found then
    raise exception 'That approval no longer exists.' using errcode = '22023';
  end if;
  v_current := app.current_task(v_task.subject_type, v_task.subject_id);
  if v_task.status <> 'open' or v_current.id is distinct from v_task.id then
    raise exception 'This step is not waiting for a decision.' using errcode = '22023';
  end if;
  if not app.can_act_on_task(v_task) then
    raise exception 'This step is %''s to decide.', coalesce(app.person_name(v_task.approver_id), v_task.label)
      using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'changes_requested', 'rejected') then
    raise exception 'Approve, request changes or reject.' using errcode = '22023';
  end if;
  if p_decision <> 'approved' and v_comment is null then
    raise exception 'Say what needs to change, or why.' using errcode = '22023';
  end if;
  if length(coalesce(v_comment, '')) > 2000 then
    raise exception 'Keep the comment to 2,000 characters or fewer.' using errcode = '22023';
  end if;

  if v_task.subject_type = 'request' then
    select * into v_req from public.hiring_requests where id = v_task.subject_id for update;
    if v_req.status <> 'submitted' then
      raise exception 'This request is % — nothing to decide.', replace(v_req.status, '_', ' ') using errcode = '22023';
    end if;
    if v_req.requested_by = v_me and not app.is_admin() then
      raise exception 'Requesters cannot decide their own hiring request' using errcode = '42501';
    end if;
  else
    select * into v_offer from public.offers where id = v_task.subject_id for update;
    if v_offer.status <> 'in_approval' then
      raise exception 'This offer is not in approval.' using errcode = '22023';
    end if;
    if p_decision = 'changes_requested' then p_decision := 'rejected'; end if;
  end if;

  update public.approval_tasks
     set status = p_decision, comment = v_comment, acted_by = v_me, acted_at = now()
   where id = v_task.id;

  perform set_config('app.request_lifecycle', 'on', true);
  if p_decision = 'approved' then
    v_next := app.current_task(v_task.subject_type, v_task.subject_id);
    if v_next.id is not null then
      perform app.notify_task(v_next);
    elsif v_task.subject_type = 'request' then
      update public.hiring_requests set status = 'approved', decided_by = v_me, decided_at = now(), change_reason = null
       where id = v_req.id;
    else
      update public.offers set status = 'approved', approved_by = v_me, returned_reason = null where id = v_offer.id;
    end if;
  elsif v_task.subject_type = 'request' then
    if p_decision = 'rejected' then
      update public.approval_tasks set status = 'superseded'
       where subject_type = 'request' and subject_id = v_req.id and status = 'open';
    end if;
    update public.hiring_requests set status = p_decision, change_reason = v_comment, decided_by = v_me, decided_at = now()
     where id = v_req.id;
  else
    update public.approval_tasks set status = 'superseded'
     where subject_type = 'offer' and subject_id = v_offer.id and status = 'open';
    update public.offers set status = 'draft', approved_by = null, returned_reason = v_comment where id = v_offer.id;
    if v_offer.created_by is not null and v_offer.created_by <> v_me then
      perform app.notify(v_offer.created_by, v_offer.company_id, 'offer.returned',
        'Offer sent back: ' || coalesce(app.task_subject_title(v_task), 'offer'), v_comment,
        '/hiring?tab=applicants', 'offer', v_offer.id, 'offer.returned:' || v_task.id);
    end if;
  end if;
  perform set_config('app.request_lifecycle', 'off', true);

  return jsonb_build_object('decision', p_decision,
    'subject_status', case when v_task.subject_type = 'request'
      then (select status from public.hiring_requests where id = v_task.subject_id)
      else (select status from public.offers where id = v_task.subject_id) end);
end $$;

create or replace function public.decide_approval(p_task_id uuid, p_decision text, p_comment text default null)
returns jsonb
language sql security definer set search_path = public as $$
  select app.decide_task(p_task_id, p_decision, p_comment)
$$;
grant execute on function public.decide_approval(uuid, text, text) to authenticated;

/** My approvals (9.4): the current steps I may decide, newest first. */
create or replace function public.my_approvals() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_to_json(x) order by x.created_at desc), '[]'::jsonb) from (
    select t.id, t.subject_type, t.subject_id, t.company_id, co.name as company, t.round, t.position, t.label,
           t.created_at, app.task_subject_title(t) as title,
           (select count(*) from public.approval_tasks t2 where t2.subject_type = t.subject_type
              and t2.subject_id = t.subject_id and t2.round = t.round) as steps,
           case when t.subject_type = 'offer' then (select jsonb_build_object('terms', o.terms, 'in_band', o.in_band,
                  'band_note', o.band_note, 'application_id', o.application_id) from public.offers o where o.id = t.subject_id)
                else (select jsonb_build_object('headcount', r.headcount, 'reason', r.reason, 'budget', r.budget,
                  'requester', app.person_name(r.requested_by)) from public.hiring_requests r where r.id = t.subject_id) end as detail,
           t.approver_id is not null and t.approver_id <> app.current_person_id() as as_delegate
      from public.approval_tasks t
      join public.companies co on co.id = t.company_id
     where t.status = 'open'
       and t.id = (app.current_task(t.subject_type, t.subject_id)).id
       and (t.approver_id = app.current_person_id()
            or (t.approver_id is not null and app.is_absent(t.approver_id)
                and exists (select 1 from public.approval_delegates d
                             where d.person_id = t.approver_id and d.delegate_id = app.current_person_id()))
            or (t.capability is not null and app.has_capability(t.company_id, t.capability)))
       and not (t.subject_type = 'request' and exists (select 1 from public.hiring_requests r
                                                       where r.id = t.subject_id and r.requested_by = app.current_person_id()))
  ) x
$$;
grant execute on function public.my_approvals() to authenticated;

-- --------------------------------------------------------- request wiring
create or replace function app.request_approval_flow() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_asked public.approval_tasks;
  v_open public.approval_tasks;
  v_lifecycle boolean := coalesce(current_setting('app.request_lifecycle', true), '') = 'on';
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  -- First submission: a fresh route. The first step's approvers already
  -- heard through 0034's hiring.submitted when the route is the default one.
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.start_approval('request', new.id, new.company_id, 'request',
      exists (select 1 from public.approval_routes r where r.company_id = new.company_id and r.kind = 'request'));
    return new;
  end if;
  -- Resubmitted after changes: back at the step that asked (2.3).
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
  -- A decision written straight onto the request (the old path): the route follows it.
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
create trigger t4_approval_flow after insert or update of status on public.hiring_requests
  for each row execute function app.request_approval_flow();

-- Requests waiting today get their route now, quietly.
do $$
declare r record;
begin
  for r in select id, company_id from public.hiring_requests where status = 'submitted' loop
    perform app.start_approval('request', r.id, r.company_id, 'request', false);
  end loop;
end $$;

-- ----------------------------------------------------------- offer wiring
create or replace function app.offer_band(p_offer_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_terms jsonb;
  v_budget jsonb;
  v_salary numeric;
  v_min numeric;
  v_max numeric;
begin
  select o.terms, r.budget into v_terms, v_budget
    from public.offers o
    join public.applications a on a.id = o.application_id
    left join public.jobs j on j.id = a.job_id
    left join public.hiring_requests r on r.id = j.hiring_request_id
   where o.id = p_offer_id;
  if v_budget is null or jsonb_typeof(v_budget) <> 'object'
     or (v_budget->>'min') is null and (v_budget->>'max') is null then
    return jsonb_build_object('in_band', true, 'note', 'No salary band on the request');
  end if;
  v_salary := nullif(v_terms->>'salary', '')::numeric;
  v_min := nullif(v_budget->>'min', '')::numeric;
  v_max := nullif(v_budget->>'max', '')::numeric;
  if coalesce(upper(v_budget->>'currency'), upper(v_terms->>'currency')) is distinct from upper(v_terms->>'currency') then
    return jsonb_build_object('in_band', false, 'note', 'Band is in ' || upper(v_budget->>'currency') || ', offer in ' || upper(v_terms->>'currency'));
  end if;
  if v_salary is null then
    return jsonb_build_object('in_band', false, 'note', 'Offer has no salary');
  end if;
  if (v_min is not null and v_salary < v_min) or (v_max is not null and v_salary > v_max) then
    return jsonb_build_object('in_band', false, 'note',
      'Outside the band ' || coalesce(v_min::text, '…') || '–' || coalesce(v_max::text, '…') || ' ' || coalesce(upper(v_budget->>'currency'), ''));
  end if;
  return jsonb_build_object('in_band', true, 'note',
    'Inside the band ' || coalesce(v_min::text, '…') || '–' || coalesce(v_max::text, '…') || ' ' || coalesce(upper(v_budget->>'currency'), ''));
end $$;

create or replace function public.advance_offer(
  p_offer_id uuid,
  p_to_status text,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_offer record;
  v_band jsonb;
  v_task public.approval_tasks;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_offer from public.offers where id = p_offer_id for update;
  if not found then
    raise exception 'Offer not found.';
  end if;
  if v_offer.status in ('accepted', 'declined', 'withdrawn') then
    raise exception 'This offer is already %.', v_offer.status;
  end if;

  case p_to_status
    when 'in_approval' then
      if v_offer.status <> 'draft' then
        raise exception 'Only a draft offer can be submitted for approval.';
      end if;
      if not app.has_capability(v_offer.company_id, 'candidates.review') then
        raise exception 'Submitting an offer requires candidates.review in this company.' using errcode = '42501';
      end if;
      v_band := app.offer_band(p_offer_id);
      update public.offers set status = 'in_approval', in_band = (v_band->>'in_band')::boolean,
             band_note = v_band->>'note', returned_reason = null
       where id = p_offer_id;
      perform app.start_approval('offer', p_offer_id, v_offer.company_id,
        case when (v_band->>'in_band')::boolean then 'offer_in_band' else 'offer_out_of_band' end, true);

    when 'approved' then
      if v_offer.status <> 'in_approval' then
        raise exception 'Only an offer in approval can be approved.';
      end if;
      v_task := app.current_task('offer', p_offer_id);
      if v_task.id is null then
        raise exception 'This offer has no approval step waiting.' using errcode = '22023';
      end if;
      perform app.decide_task(v_task.id, 'approved', p_reason);

    when 'draft' then
      if v_offer.status <> 'in_approval' then
        raise exception 'Only an offer in approval can be sent back to draft.';
      end if;
      v_task := app.current_task('offer', p_offer_id);
      if v_task.id is null then
        raise exception 'This offer has no approval step waiting.' using errcode = '22023';
      end if;
      perform app.decide_task(v_task.id, 'rejected', coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Sent back to draft'));

    when 'extended' then
      if v_offer.status <> 'approved' then
        raise exception 'Only an approved offer can be extended to the candidate.';
      end if;
      if not app.has_capability(v_offer.company_id, 'candidates.review') then
        raise exception 'Extending an offer requires candidates.review in this company.' using errcode = '42501';
      end if;
      update public.offers set status = 'extended', extended_at = now() where id = p_offer_id;

    when 'accepted', 'declined' then
      if v_offer.status <> 'extended' then
        raise exception 'Only an extended offer can be accepted or declined.';
      end if;
      if not app.has_capability(v_offer.company_id, 'candidates.review') then
        raise exception 'Recording the candidate''s answer requires candidates.review in this company.'
          using errcode = '42501';
      end if;
      if p_to_status = 'declined' and (p_reason is null or length(trim(p_reason)) = 0) then
        raise exception 'Record why the candidate declined.';
      end if;
      update public.offers
        set status = p_to_status,
            accepted_at = case when p_to_status = 'accepted' then now() else accepted_at end,
            decline_reason = case when p_to_status = 'declined' then trim(p_reason) else decline_reason end
        where id = p_offer_id;

    when 'withdrawn' then
      if not app.has_capability(v_offer.company_id, 'candidates.review') then
        raise exception 'Withdrawing an offer requires candidates.review in this company.' using errcode = '42501';
      end if;
      update public.offers set status = 'withdrawn', decline_reason = nullif(trim(coalesce(p_reason, '')), '')
        where id = p_offer_id;
      update public.approval_tasks set status = 'superseded'
       where subject_type = 'offer' and subject_id = p_offer_id and status = 'open';

    else
      raise exception 'Unknown offer status: %', p_to_status;
  end case;

  return jsonb_build_object('status', (select status from public.offers where id = p_offer_id));
end $$;

-- Offers in approval today get their route now, quietly.
do $$
declare o record; v_band jsonb;
begin
  for o in select id, company_id from public.offers where status = 'in_approval' loop
    v_band := app.offer_band(o.id);
    update public.offers set in_band = (v_band->>'in_band')::boolean, band_note = v_band->>'note' where id = o.id;
    perform app.start_approval('offer', o.id, o.company_id,
      case when (v_band->>'in_band')::boolean then 'offer_in_band' else 'offer_out_of_band' end, false);
  end loop;
end $$;

-- The app's door for deciding a request: the current step, whoever's it is.
create or replace function public.decide_hiring_request(p_request_id uuid, p_decision text, p_comment text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_task public.approval_tasks := app.current_task('request', p_request_id);
begin
  if v_task.id is null then
    raise exception 'This request has no approval step waiting.' using errcode = '22023';
  end if;
  return app.decide_task(v_task.id, p_decision, p_comment);
end $$;
grant execute on function public.decide_hiring_request(uuid, text, text) to authenticated;

-- With a route of its own, a company's requests are decided step by step only.
create or replace function app.guard_routed_decision() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null
     and coalesce(current_setting('app.request_lifecycle', true), '') <> 'on'
     and old.status = 'submitted' and new.status in ('approved', 'rejected', 'changes_requested')
     and exists (select 1 from public.approval_routes r where r.company_id = new.company_id and r.kind = 'request') then
    raise exception 'This company has an approval route — decide it from My approvals.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger t1_guard_routed before update of status on public.hiring_requests
  for each row execute function app.guard_routed_decision();

commit;
