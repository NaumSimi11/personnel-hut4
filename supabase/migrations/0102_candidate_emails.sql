-- 0102_candidate_emails.sql
-- Emails to candidates (Hiring Module user flows, 11 Nov 2026: 4.4 and the
-- closing rules of section 5). PeopleOS never wrote to a candidate before.
--
--   * received   — automatic, when somebody applies through the careers page
--                  (4.4). A head-hunted or hand-added person did not apply,
--                  so nobody tells them they did.
--   * rejected   — when HR rejects and ticks "Email the candidate".
--   * withdrawn  — the confirmation when HR records a withdrawal and ticks it.
--
-- The rows are a queue: the server renders and sends them (the same kick
-- that sends notifications) and records the outcome on each row. Never to a
-- candidate marked Do not contact, never twice of a kind per application.
-- Replies go to the company's HR inbox when one is set.

begin;

create table public.candidate_emails (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  kind text not null check (kind in ('received', 'rejected', 'withdrawn')),
  email_to text not null,
  reply_to text,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  error text,
  attempts int not null default 0,
  sent_at timestamptz,
  created_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  unique (application_id, kind)
);
create index candidate_emails_pending_idx on public.candidate_emails (created_at) where status = 'pending';

alter table public.candidate_emails enable row level security;
create policy sel on public.candidate_emails for select to authenticated
  using (app.has_capability(company_id, 'candidates.view'));
grant select on public.candidate_emails to authenticated;
grant all on public.candidate_emails to service_role;

-- -------------------------------------------------------------- the queue
/** One email for one application, or the reason there is none. */
create or replace function app.queue_candidate_email(p_application_id uuid, p_kind text, p_actor uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v record;
begin
  select a.id, a.company_id, a.candidate_id, c.full_name, c.email, c.do_not_contact,
         j.title as job_title, co.name as company_name, co.hr_notification_email
    into v
    from public.applications a
    join public.candidates c on c.id = a.candidate_id
    join public.companies co on co.id = a.company_id
    left join public.jobs j on j.id = a.job_id
   where a.id = p_application_id;
  if not found then return 'missing'; end if;
  if v.do_not_contact then return 'do_not_contact'; end if;
  if v.email is null or v.email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then return 'no_email'; end if;
  insert into public.candidate_emails (application_id, candidate_id, company_id, kind, email_to, reply_to, data, created_by)
  values (v.id, v.candidate_id, v.company_id, p_kind, v.email, v.hr_notification_email,
          jsonb_build_object('candidate', v.full_name, 'job', coalesce(v.job_title, 'the role'), 'company', v.company_name),
          p_actor)
  on conflict (application_id, kind) do nothing;
  return case when found then 'queued' else 'already' end;
end $$;

-- 4.4: an application through the careers page.
create or replace function app.email_on_application() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if new.source_key = 'careers_page' then
    perform app.queue_candidate_email(new.id, 'received', null);
  end if;
  return new;
end $$;
create trigger t9_email_received after insert on public.applications
  for each row execute function app.email_on_application();

/**
 * The app's door for rejection and withdrawal emails, after the status is
 * set: each application must be closed with the matching outcome, and the
 * hiring manager's own calls (contact in future, do not contact) are not a
 * withdrawal by the candidate.
 */
create or replace function public.email_candidates(p_application_ids uuid[], p_kind text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_id uuid;
  v_app record;
  v_result text;
  v_queued int := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_kind not in ('rejected', 'withdrawn') then
    raise exception 'Only rejection and withdrawal emails are sent by hand.' using errcode = '22023';
  end if;
  for v_id in select distinct u.id from unnest(coalesce(p_application_ids, '{}')) u(id) loop
    select a.id, a.company_id, c.full_name, s.outcome, coalesce(s.hm_only, false) as hm_only
      into v_app
      from public.applications a
      join public.candidates c on c.id = a.candidate_id
      left join public.application_sub_statuses s on s.key = a.sub_status_key
     where a.id = v_id;
    if not found then
      raise exception 'That application no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_app.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" to email candidates here.' using errcode = '42501';
    end if;
    if (p_kind = 'rejected' and v_app.outcome is distinct from 'rejected')
       or (p_kind = 'withdrawn' and (v_app.outcome is distinct from 'withdrew' or v_app.hm_only)) then
      v_skipped := v_skipped || jsonb_build_object('name', v_app.full_name, 'why', 'status');
      continue;
    end if;
    v_result := app.queue_candidate_email(v_id, p_kind, v_me);
    if v_result = 'queued' then
      v_queued := v_queued + 1;
    else
      v_skipped := v_skipped || jsonb_build_object('name', v_app.full_name, 'why', v_result);
    end if;
  end loop;
  return jsonb_build_object('queued', v_queued, 'skipped', v_skipped);
end $$;
grant execute on function public.email_candidates(uuid[], text) to authenticated;

commit;
