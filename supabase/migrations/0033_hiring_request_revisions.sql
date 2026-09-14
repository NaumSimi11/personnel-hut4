-- 0033_hiring_request_revisions.sql
-- Hiring-request revision flow (plan 042): request changes → the requester
-- reads why → edits → resubmits → the approver reviews again. The database
-- keeps the history and the gates:
--   * asking for changes needs jobs.approve, never on one's own request
--     (platform admins excepted, as for approvals);
--   * resubmitting from "changes requested" is the requester's (or
--     jobs.edit / admin) and clears the decision;
--   * the content (title, reason, headcount, start date, manager) is locked
--     once submitted — only a draft or a request sent back may change.
-- Service paths without a user (auth.uid() null) bypass, as before.

create table public.hiring_request_history (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.hiring_requests(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  kind text not null check (kind in ('submitted', 'changes_requested', 'rejected', 'approved', 'resubmitted', 'cancelled', 'draft')),
  reason text,
  snapshot jsonb not null,
  actor_id uuid references public.people(id),
  at timestamptz not null default now()
);
create index hiring_request_history_request_idx on public.hiring_request_history (request_id, at);
alter table public.hiring_request_history enable row level security;
create policy sel on public.hiring_request_history for select to authenticated
  using (app.has_capability(company_id, 'jobs.view'));
grant select on public.hiring_request_history to authenticated;
grant all on public.hiring_request_history to service_role;

create or replace function app.gate_hiring_request_transitions() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prev text;
  me uuid := app.current_person_id();
  mine boolean;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then prev := old.status; end if;
  mine := new.requested_by is not distinct from me;

  -- Deciding: approve / reject / send back — an approver, not the requester.
  if new.status in ('approved', 'rejected', 'changes_requested') and new.status is distinct from prev then
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
  end if;

  -- The content is locked once submitted; a request sent back (or a draft) may change.
  if tg_op = 'UPDATE' and prev not in ('draft', 'changes_requested')
     and (new.title, new.reason, new.headcount, new.target_start_date, new.hiring_manager_id, new.budget)
         is distinct from (old.title, old.reason, old.headcount, old.target_start_date, old.hiring_manager_id, old.budget) then
    raise exception 'A submitted request cannot be edited; ask for changes first.';
  end if;
  return new;
end $$;

-- History: one row per step, written by the database so nothing is missed.
create or replace function app.log_hiring_request_history() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_kind text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  v_kind := case
    when tg_op = 'UPDATE' and new.status = 'submitted' and old.status = 'changes_requested' then 'resubmitted'
    else new.status end;
  insert into public.hiring_request_history (request_id, company_id, kind, reason, snapshot, actor_id)
  values (new.id, new.company_id, v_kind,
          case when v_kind in ('changes_requested', 'rejected') then new.change_reason else null end,
          jsonb_build_object('title', new.title, 'reason', new.reason, 'headcount', new.headcount,
                             'target_start_date', new.target_start_date, 'hiring_manager_id', new.hiring_manager_id),
          app.current_person_id());
  return new;
end $$;
create trigger t3_history after insert or update on public.hiring_requests
  for each row execute function app.log_hiring_request_history();
