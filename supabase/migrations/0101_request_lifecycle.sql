-- 0101_request_lifecycle.sql
-- Hiring request: On hold, Resume, Cancelled, Filled (Hiring Module user
-- flows, 11 Nov 2026: steps 7.3, 8.1, 8.2, 8.3).
--
--   * Hold (8.1): a submitted or approved request, with a reason and a review
--     date. Its jobs that are not closed or filled go On hold too, which
--     takes them off the careers page; each remembers where it was.
--   * Resume (8.2): back to the status before the hold, jobs likewise.
--   * Cancel (8.3): any time before Filled, with a reason. Its live jobs
--     close with that reason; the candidates still in play are counted and
--     returned so the app can offer to withdraw them (the spec's "prompt").
--   * Filled (7.3): when every job of the request is filled, the request is
--     Filled; a job reopened from filled puts it back to Approved.
--
-- Who: the requester, or anyone holding jobs.approve or jobs.edit in the
-- company, or an admin ("HR or the requester").
-- Holding, resuming and filling go through these doors only: the gate
-- refuses any other write that enters or leaves on_hold / filled.

begin;

alter table public.hiring_requests drop constraint hiring_requests_status_check;
alter table public.hiring_requests add constraint hiring_requests_status_check check (status in
  ('draft', 'submitted', 'changes_requested', 'approved', 'rejected', 'cancelled', 'on_hold', 'filled'));
alter table public.hiring_requests
  add column status_before_hold text check (status_before_hold in ('submitted', 'approved')),
  add column hold_reason text,
  add column hold_review_on date,
  add column cancel_reason text;

alter table public.jobs
  add column status_before_hold text check (status_before_hold in ('draft', 'ready', 'open'));

alter table public.hiring_request_history drop constraint hiring_request_history_kind_check;
alter table public.hiring_request_history add constraint hiring_request_history_kind_check check (kind in
  ('submitted', 'changes_requested', 'rejected', 'approved', 'resubmitted', 'cancelled', 'draft',
   'on_hold', 'resumed', 'filled', 'reopened'));

-- ------------------------------------------------------------------ the gate
-- 0033's rules, plus: on_hold and filled are entered and left only through
-- the lifecycle doors below (they set app.request_lifecycle for the
-- transaction), and those moves are not "decisions".
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

  -- Deciding: approve / reject / send back — an approver, not the requester.
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

  -- Resubmitting after changes were requested: the requester's move (or jobs.edit / admin).
  if tg_op = 'UPDATE' and new.status = 'submitted' and prev = 'changes_requested' then
    if not (mine or app.has_capability(new.company_id, 'jobs.edit') or app.is_admin()) then
      raise exception 'Only the requester can revise and resubmit this request'
        using errcode = '42501';
    end if;
    new.decided_by := null;
    new.decided_at := null;
    new.change_reason := null;
  end if;

  -- The content is locked once submitted; a request sent back (or a draft) may change.
  if tg_op = 'UPDATE' and prev not in ('draft', 'changes_requested')
     and (new.title, new.reason, new.headcount, new.target_start_date, new.hiring_manager_id, new.budget)
         is distinct from (old.title, old.reason, old.headcount, old.target_start_date, old.hiring_manager_id, old.budget) then
    raise exception 'A submitted request cannot be edited; ask for changes first.';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- history
create or replace function app.log_hiring_request_history() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_kind text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  v_kind := case
    when tg_op = 'UPDATE' and new.status = 'submitted' and old.status = 'changes_requested' then 'resubmitted'
    when tg_op = 'UPDATE' and old.status = 'on_hold' and new.status in ('submitted', 'approved') then 'resumed'
    when tg_op = 'UPDATE' and old.status = 'filled' and new.status = 'approved' then 'reopened'
    else new.status end;
  insert into public.hiring_request_history (request_id, company_id, kind, reason, snapshot, actor_id)
  values (new.id, new.company_id, v_kind,
          case when v_kind in ('changes_requested', 'rejected') then new.change_reason
               when v_kind = 'on_hold' then new.hold_reason
               when v_kind = 'cancelled' then new.cancel_reason
               else null end,
          jsonb_build_object('title', new.title, 'reason', new.reason, 'headcount', new.headcount,
                             'target_start_date', new.target_start_date, 'hiring_manager_id', new.hiring_manager_id),
          app.current_person_id());
  return new;
end $$;

-- ------------------------------------------------------------------- doors
create or replace function app.may_steer_request(p_request public.hiring_requests) returns boolean
language sql stable security definer set search_path = public as $$
  select p_request.requested_by = app.current_person_id()
      or app.has_capability(p_request.company_id, 'jobs.approve')
      or app.has_capability(p_request.company_id, 'jobs.edit')
$$;

create or replace function app.request_for_lifecycle(p_request_id uuid) returns public.hiring_requests
language plpgsql security definer set search_path = public as $$
declare v_req public.hiring_requests;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_req from public.hiring_requests where id = p_request_id for update;
  if not found then
    raise exception 'That hiring request no longer exists.' using errcode = '22023';
  end if;
  if not app.may_steer_request(v_req) then
    raise exception 'Only the requester or HR can do this.' using errcode = '42501';
  end if;
  return v_req;
end $$;

create or replace function public.hold_hiring_request(p_request_id uuid, p_reason text, p_review_on date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req public.hiring_requests := app.request_for_lifecycle(p_request_id);
  v_reason text := trim(coalesce(p_reason, ''));
  v_jobs int;
begin
  if v_req.status not in ('submitted', 'approved') then
    raise exception 'Only a pending or approved request can go on hold (this one is %).', replace(v_req.status, '_', ' ')
      using errcode = '22023';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Say why the request is on hold.' using errcode = '22023';
  end if;
  if length(v_reason) > 2000 then
    raise exception 'Keep the reason to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  if p_review_on is not null and p_review_on < current_date then
    raise exception 'The review date has passed — pick a date from today on.' using errcode = '22023';
  end if;
  perform set_config('app.request_lifecycle', 'on', true);
  update public.hiring_requests
     set status_before_hold = status, status = 'on_hold', hold_reason = v_reason, hold_review_on = p_review_on
   where id = v_req.id;
  update public.jobs
     set status_before_hold = status, status = 'on_hold'
   where hiring_request_id = v_req.id and status in ('draft', 'ready', 'open');
  get diagnostics v_jobs = row_count;
  perform set_config('app.request_lifecycle', 'off', true);
  return jsonb_build_object('status', 'on_hold', 'jobs_paused', v_jobs);
end $$;

create or replace function public.resume_hiring_request(p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req public.hiring_requests := app.request_for_lifecycle(p_request_id);
  v_back text;
  v_jobs int;
begin
  if v_req.status <> 'on_hold' then
    raise exception 'This request is not on hold.' using errcode = '22023';
  end if;
  v_back := coalesce(v_req.status_before_hold, 'submitted');
  perform set_config('app.request_lifecycle', 'on', true);
  update public.hiring_requests
     set status = v_back, status_before_hold = null, hold_reason = null, hold_review_on = null
   where id = v_req.id;
  update public.jobs
     set status = status_before_hold, status_before_hold = null
   where hiring_request_id = v_req.id and status = 'on_hold' and status_before_hold is not null;
  get diagnostics v_jobs = row_count;
  perform set_config('app.request_lifecycle', 'off', true);
  return jsonb_build_object('status', v_back, 'jobs_resumed', v_jobs);
end $$;

create or replace function public.cancel_hiring_request(p_request_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req public.hiring_requests := app.request_for_lifecycle(p_request_id);
  v_reason text := trim(coalesce(p_reason, ''));
  v_me uuid := app.current_person_id();
  v_jobs uuid[];
  v_in_play int;
begin
  if v_req.status in ('filled', 'cancelled', 'rejected') then
    raise exception 'A % request cannot be cancelled.', v_req.status using errcode = '22023';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Say why the request is cancelled.' using errcode = '22023';
  end if;
  if length(v_reason) > 2000 then
    raise exception 'Keep the reason to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  perform set_config('app.request_lifecycle', 'on', true);
  update public.hiring_requests
     set status = 'cancelled', cancel_reason = v_reason, status_before_hold = null
   where id = v_req.id;
  with closed as (
    update public.jobs
       set status = 'closed', closed_at = now(), closed_by = v_me,
           closed_reason = 'Request cancelled: ' || v_reason, status_before_hold = null
     where hiring_request_id = v_req.id and status not in ('closed', 'filled')
    returning id)
  select coalesce(array_agg(id), '{}') into v_jobs from closed;
  perform set_config('app.request_lifecycle', 'off', true);
  select count(*) into v_in_play from public.applications a
   where a.job_id = any (v_jobs) and a.in_play;
  return jsonb_build_object('status', 'cancelled', 'jobs_closed', v_jobs, 'in_play', v_in_play);
end $$;

grant execute on function public.hold_hiring_request(uuid, text, date),
  public.resume_hiring_request(uuid), public.cancel_hiring_request(uuid, text) to authenticated;

-- ------------------------------------------------------------- Filled (7.3)
create or replace function app.request_follows_jobs() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  if new.hiring_request_id is null or new.status is not distinct from old.status then return new; end if;
  select status into v_status from public.hiring_requests where id = new.hiring_request_id;
  if new.status = 'filled' and v_status = 'approved'
     and not exists (select 1 from public.jobs j
                      where j.hiring_request_id = new.hiring_request_id and j.status <> 'filled') then
    perform set_config('app.request_lifecycle', 'on', true);
    update public.hiring_requests set status = 'filled' where id = new.hiring_request_id;
    perform set_config('app.request_lifecycle', 'off', true);
  elsif old.status = 'filled' and new.status <> 'filled' and v_status = 'filled' then
    perform set_config('app.request_lifecycle', 'on', true);
    update public.hiring_requests set status = 'approved' where id = new.hiring_request_id;
    perform set_config('app.request_lifecycle', 'off', true);
  end if;
  return new;
end $$;
create trigger t8_request_follows after update of status on public.jobs
  for each row execute function app.request_follows_jobs();

-- Requests whose jobs are already all filled.
alter table public.hiring_requests disable trigger user;
update public.hiring_requests r set status = 'filled'
 where r.status = 'approved'
   and exists (select 1 from public.jobs j where j.hiring_request_id = r.id)
   and not exists (select 1 from public.jobs j where j.hiring_request_id = r.id and j.status <> 'filled');
alter table public.hiring_requests enable trigger user;

commit;
