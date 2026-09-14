-- 0034_notifications.sql
-- Notifications on both sides (plan 043, after Field Notebook's model: an HR
-- recipient per company, the person's own address for what concerns them,
-- and every action saying whether the mail went). The database creates the
-- rows — one per recipient, deduplicated — so nothing that happens goes
-- untold; the service delivers the emails from the queue and records the
-- outcome on the row; the app shows the same rows under the bell.

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  company_id uuid references public.companies(id),
  kind text not null,                       -- leave.requested, leave.decided, hiring.assigned, …
  title text not null,
  body text,
  link text,                                -- an app path: /leave?tab=requests, /hiring, /me …
  entity_type text,
  entity_id uuid,
  dedupe_key text not null unique,
  email_to text,                            -- where the mail goes, decided when the row is made
  email_status text not null default 'pending' check (email_status in ('pending', 'sent', 'failed', 'skipped')),
  email_error text,
  email_attempts int not null default 0,
  email_sent_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_person_idx on public.notifications (person_id, created_at desc);
create index notifications_unread_idx on public.notifications (person_id) where read_at is null;
create index notifications_pending_idx on public.notifications (created_at) where email_status = 'pending';
alter table public.notifications enable row level security;
create policy sel on public.notifications for select to authenticated using (app.is_self(person_id));
grant select on public.notifications to authenticated;
grant all on public.notifications to service_role;

-- Per company: where HR-side mail goes when one shared inbox handles it
-- (Field Notebook's "active HR recipient"); empty = each approver's own
-- address. Admins edit it on the company Settings tab.
alter table public.companies add column hr_notification_email text
  check (hr_notification_email is null or hr_notification_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$');

/** Mark my notifications read; null = all of mine. */
create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns int
language plpgsql security definer set search_path = public as $$
declare v_me uuid := app.current_person_id(); v_n int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  update public.notifications set read_at = now()
    where person_id = v_me and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- ------------------------------------------------------------- helpers
/**
 * One notification for one person. The mail address is decided here:
 * `p_hr_side` rows go to the company's HR inbox when one is set, otherwise
 * to the person's work email; no address → the mail is skipped, the in-app
 * row still shows. The dedupe key names the event; the recipient is
 * appended here, so one event reaches every recipient exactly once.
 */
create or replace function app.notify(
  p_person_id uuid, p_company_id uuid, p_kind text, p_title text, p_body text, p_link text,
  p_entity_type text, p_entity_id uuid, p_dedupe_key text, p_hr_side boolean default false
) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if p_person_id is null then return; end if;
  v_email := case when p_hr_side then (select hr_notification_email from public.companies where id = p_company_id) end;
  if v_email is null then
    select work_email into v_email from public.people where id = p_person_id and archived_at is null;
  end if;
  insert into public.notifications (person_id, company_id, kind, title, body, link, entity_type, entity_id, dedupe_key, email_to, email_status)
  values (p_person_id, p_company_id, p_kind, p_title, p_body, p_link, p_entity_type, p_entity_id, p_dedupe_key || ':' || p_person_id,
          v_email, case when v_email is null then 'skipped' else 'pending' end)
  on conflict (dedupe_key) do nothing;
end $$;

/** Who holds a capability in a company (grants, not admins — admins are not spammed). */
create or replace function app.capability_holders(p_company_id uuid, p_cap text) returns setof uuid
language sql stable security definer set search_path = public as $$
  select distinct g.person_id from public.access_grants g
  join public.grant_capabilities gc on gc.grant_id = g.id
  join public.people p on p.id = g.person_id and p.archived_at is null
  where g.company_id = p_company_id and gc.capability_key = p_cap
$$;

/** The company's approvers for a capability, or its HR contact / director when nobody holds it. */
create or replace function app.approvers_or_contacts(p_company_id uuid, p_cap text) returns setof uuid
language plpgsql stable security definer set search_path = public as $$
begin
  return query select * from app.capability_holders(p_company_id, p_cap);
  if not found then
    return query select id from (select hr_contact_person_id as id from public.companies where id = p_company_id
                                 union select director_person_id from public.companies where id = p_company_id) c where id is not null;
  end if;
end $$;

create or replace function app.person_name(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select full_name from public.people where id = p_id), 'Someone')
$$;

create or replace function app.span_text(p_start date, p_end date) returns text
language sql immutable as $$
  select case when p_start = p_end then to_char(p_start, 'DD Mon YYYY')
              else to_char(p_start, 'DD Mon') || ' → ' || to_char(p_end, 'DD Mon YYYY') end
$$;

-- --------------------------------------------------------------- leave
create or replace function app.notify_leave() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := app.person_name(new.person_id);
  v_type text := coalesce((select label from public.leave_types where key = new.leave_type_key), new.leave_type_key);
  v_span text := app.span_text(new.start_date, new.end_date);
  v_days text := new.working_days || ' working ' || case when new.working_days = 1 then 'day' else 'days' end;
  v_me uuid := app.current_person_id();
  r uuid;
begin
  -- A new pending request: the approvers.
  if tg_op = 'INSERT' and new.status = 'pending' then
    for r in select * from app.approvers_or_contacts(new.company_id, 'leave.approve') loop
      if r <> new.person_id then
        perform app.notify(r, new.company_id, 'leave.requested', 'Leave request from ' || v_who,
          v_type || ' · ' || v_span || ' · ' || v_days || coalesce(' — "' || new.note || '"', ''),
          '/leave?tab=requests', 'leave_request', new.id, 'leave.requested:' || new.id, true);
      end if;
    end loop;
    return new;
  end if;
  if tg_op <> 'UPDATE' then return new; end if;
  -- Decided: the person.
  if new.status in ('approved', 'rejected') and old.status = 'pending' then
    perform app.notify(new.person_id, new.company_id, 'leave.decided',
      'Your leave was ' || new.status || ': ' || v_span,
      v_type || ' · ' || v_days || coalesce(' — ' || new.decision_note, '') || ' · by ' || app.person_name(new.decided_by),
      '/me', 'leave_request', new.id, 'leave.decided:' || new.id || ':' || new.status);
  end if;
  -- Cancelled by someone else: the person.
  if new.status = 'cancelled' and old.status <> 'cancelled' and new.cancelled_by is distinct from new.person_id then
    perform app.notify(new.person_id, new.company_id, 'leave.cancelled',
      'Your leave was cancelled: ' || v_span,
      coalesce(new.cancellation_reason, '') || ' · by ' || app.person_name(new.cancelled_by),
      '/me', 'leave_request', new.id, 'leave.cancelled:' || new.id);
  end if;
  -- An ask to cancel: the approvers.
  if new.cancellation_requested_at is not null and new.cancellation_requested_at is distinct from old.cancellation_requested_at then
    for r in select * from app.approvers_or_contacts(new.company_id, 'leave.approve') loop
      if r <> new.person_id then
        perform app.notify(r, new.company_id, 'leave.cancel_asked', v_who || ' asks to cancel leave: ' || v_span,
          coalesce(new.cancellation_request_reason, ''), '/leave?tab=requests', 'leave_request', new.id,
          'leave.cancel_asked:' || new.id || ':' || new.cancellation_requested_at, true);
      end if;
    end loop;
  end if;
  -- The ask declined: the person.
  if new.cancellation_declined_at is not null and new.cancellation_declined_at is distinct from old.cancellation_declined_at then
    perform app.notify(new.person_id, new.company_id, 'leave.cancel_declined', 'Your leave stands: ' || v_span,
      coalesce(new.cancellation_decline_note, ''), '/me', 'leave_request', new.id,
      'leave.cancel_declined:' || new.id || ':' || new.cancellation_declined_at);
  end if;
  return new;
end $$;
create trigger t9_notify after insert or update on public.leave_requests for each row execute function app.notify_leave();

create or replace function app.notify_leave_correction() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.notify(new.person_id, new.company_id, 'leave.corrected',
    'Your leave was corrected: ' || app.span_text(new.new_start, new.new_end),
    'Was ' || app.span_text(new.old_start, new.old_end) || ' · ' || new.old_working_days || ' → ' || new.new_working_days || ' working days'
      || coalesce(' — "' || new.note || '"', '') || ' · by ' || app.person_name(new.corrected_by),
    '/me', 'leave_request', new.request_id, 'leave.corrected:' || new.id);
  return new;
end $$;
create trigger t9_notify after insert on public.leave_corrections for each row execute function app.notify_leave_correction();

-- ------------------------------------------------------------- hiring
create or replace function app.notify_hiring_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_company text := (select name from public.companies where id = new.company_id);
  v_requester text := app.person_name(new.requested_by);
  v_start text := coalesce(to_char(new.target_start_date, 'DD Mon YYYY'), 'not set');
  v_key text;
  r uuid;
begin
  -- Submitted (first time or again): approvers hear; the hiring manager is told they are assigned — awaiting approval.
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status is distinct from 'submitted') then
    v_key := case when tg_op = 'INSERT' then 'hiring.submitted:' || new.id else 'hiring.resubmitted:' || new.id || ':' || now() end;
    for r in select * from app.approvers_or_contacts(new.company_id, 'jobs.approve') loop
      if r is distinct from new.requested_by then
        perform app.notify(r, new.company_id, 'hiring.submitted',
          case when tg_op = 'INSERT' then 'Hiring request: ' else 'Revised hiring request: ' end || new.title,
          v_company || ' · requested by ' || v_requester || ' · headcount ' || new.headcount,
          '/hiring', 'hiring_request', new.id, v_key, true);
      end if;
    end loop;
    if new.hiring_manager_id is not null and new.hiring_manager_id is distinct from new.requested_by then
      perform app.notify(new.hiring_manager_id, new.company_id, 'hiring.assigned',
        'You are the hiring manager for ' || new.title,
        v_company || ' · requested by ' || v_requester || ' · target employee start ' || v_start
          || ' · awaiting approval — the assignment does not authorize recruitment to begin',
        '/hiring', 'hiring_request', new.id, 'hiring.assigned:' || new.id || ':' || new.hiring_manager_id);
    end if;
  end if;
  if tg_op <> 'UPDATE' or new.status is not distinct from old.status then return new; end if;
  -- Decided: the requester; approved: the manager may proceed.
  if new.status in ('approved', 'rejected', 'changes_requested') then
    perform app.notify(new.requested_by, new.company_id, 'hiring.decided',
      'Hiring request ' || replace(new.status, '_', ' ') || ': ' || new.title,
      case when new.status = 'approved' then 'Approved' else coalesce(new.change_reason, '') end || ' · by ' || app.person_name(new.decided_by),
      '/hiring', 'hiring_request', new.id, 'hiring.decided:' || new.id || ':' || new.status || ':' || coalesce(new.decided_at::text, ''));
    if new.status = 'approved' and new.hiring_manager_id is not null and new.hiring_manager_id is distinct from new.requested_by then
      perform app.notify(new.hiring_manager_id, new.company_id, 'hiring.go',
        'Recruitment can proceed: ' || new.title,
        v_company || ' · approved by ' || app.person_name(new.decided_by) || ' · target employee start ' || v_start,
        '/hiring', 'hiring_request', new.id, 'hiring.go:' || new.id || ':' || new.hiring_manager_id);
    end if;
  end if;
  return new;
end $$;
create trigger t9_notify after insert or update on public.hiring_requests for each row execute function app.notify_hiring_request();

-- Candidate handed to an owner.
create or replace function app.notify_application_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_candidate text; v_job text;
begin
  if new.owner_id is null or new.owner_id is not distinct from old.owner_id and new.next_action is not distinct from old.next_action then return new; end if;
  if new.owner_id = app.current_person_id() or new.stage_key in ('hired', 'rejected', 'withdrawn') then return new; end if;
  select c.full_name, j.title into v_candidate, v_job from public.applications a
    join public.candidates c on c.id = a.candidate_id join public.jobs j on j.id = a.job_id where a.id = new.id;
  perform app.notify(new.owner_id, new.company_id, 'candidate.assigned', 'Candidate assigned to you: ' || coalesce(v_candidate, 'Candidate'),
    coalesce(v_job, 'Role') || ' · ' || coalesce(new.next_action, 'set the next action') || coalesce(' · due ' || to_char(new.next_action_due, 'DD Mon YYYY'), ''),
    '/hiring/applications/' || new.id, 'application', new.id,
    'candidate.assigned:' || new.id || ':' || new.owner_id || ':' || coalesce(new.next_action, ''));
  return new;
end $$;
create trigger t9_notify after update on public.applications for each row execute function app.notify_application_owner();

-- ----------------------------------------------------------- documents
create or replace function app.notify_document_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_cat text := coalesce((select label from public.document_categories where key = new.category_key), new.category_key);
begin
  if tg_op = 'INSERT' then
    perform app.notify(new.person_id, new.company_id, 'document.requested', 'HR asks for a document: ' || v_cat,
      coalesce('Due ' || to_char(new.due_date, 'DD Mon YYYY'), 'No due date') || coalesce(' — ' || new.note, '') || ' · upload it from My workspace',
      '/me', 'document_request', new.id, 'document.requested:' || new.id);
    return new;
  end if;
  if new.status is not distinct from old.status then return new; end if;
  if new.status = 'submitted' then
    perform app.notify(new.reviewer_id, new.company_id, 'document.submitted', app.person_name(new.person_id) || ' submitted a document: ' || v_cat,
      'Review it on their record', '/people/' || new.person_id, 'document_request', new.id, 'document.submitted:' || new.id || ':' || now(), true);
  elsif new.status in ('accepted', 'needs_correction') then
    perform app.notify(new.person_id, new.company_id, 'document.reviewed',
      case when new.status = 'accepted' then 'Document accepted: ' else 'Document needs correction: ' end || v_cat,
      coalesce(new.note, ''), '/me', 'document_request', new.id, 'document.reviewed:' || new.id || ':' || new.status || ':' || now());
  end if;
  return new;
end $$;
create trigger t9_notify after insert or update on public.document_requests for each row execute function app.notify_document_request();
