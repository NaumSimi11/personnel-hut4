-- 0106_candidate_offer.sql
-- The offer reaches the candidate (Hiring Module user flows, 11 Nov 2026:
-- 6.4, 6.5a, 6.5b, 6.6, 8.7; screen 9.12).
--
--   * Sending (extending) an offer emails the candidate a private link. The
--     link opens a page with the terms, where they accept or decline (a
--     reason is asked when they decline). No PeopleOS login: the link's
--     token is the key, it works only while the offer is sent and unexpired.
--   * Two days before expiry the candidate is reminded once by email (8.7).
--   * An answer tells the offer's author and the company's offer approvers;
--     a decline says to move to the next-ranked candidate (6.5b).
--   * 6.6: an offer sent from now on needs its signed contract recorded (one
--     of the application's files) before the hire can be confirmed. Offers
--     sent before this migration are not held to it.

begin;

alter table public.offers
  add column candidate_token text unique,
  add column answered_by_candidate_at timestamptz,
  add column contract_required boolean not null default false,
  add column contract_file_id uuid references public.application_files(id) on delete set null,
  add column contract_recorded_by uuid references public.people(id),
  add column contract_recorded_at timestamptz;

-- The queue takes offer emails too; one per offer, not one per application.
alter table public.candidate_emails drop constraint candidate_emails_kind_check;
alter table public.candidate_emails add constraint candidate_emails_kind_check
  check (kind in ('received', 'rejected', 'withdrawn', 'offer', 'offer_reminder'));
alter table public.candidate_emails add column offer_id uuid references public.offers(id) on delete cascade;
alter table public.candidate_emails drop constraint candidate_emails_application_id_kind_key;
create unique index candidate_emails_once_per_application on public.candidate_emails (application_id, kind)
  where offer_id is null;
create unique index candidate_emails_once_per_offer on public.candidate_emails (offer_id, kind)
  where offer_id is not null;

-- 0102's queue, writing against the per-application index now.
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
  on conflict (application_id, kind) where offer_id is null do nothing;
  return case when found then 'queued' else 'already' end;
end $$;

-- ------------------------------------------------------ sending the offer
create or replace function app.offer_email_data(p_offer_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'candidate', c.full_name, 'job', coalesce(j.title, 'the role'), 'company', co.name,
    'token', o.candidate_token, 'salary', o.terms->>'salary', 'currency', o.terms->>'currency',
    'start_date', o.terms->>'start_date', 'expires_on', o.expires_on)
    from public.offers o
    join public.applications a on a.id = o.application_id
    join public.candidates c on c.id = a.candidate_id
    join public.companies co on co.id = a.company_id
    left join public.jobs j on j.id = a.job_id
   where o.id = p_offer_id
$$;

create or replace function app.queue_offer_email(p_offer_id uuid, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select o.id, a.id as application_id, a.company_id, c.id as candidate_id, c.email, c.do_not_contact, co.hr_notification_email
    into v
    from public.offers o
    join public.applications a on a.id = o.application_id
    join public.candidates c on c.id = a.candidate_id
    join public.companies co on co.id = a.company_id
   where o.id = p_offer_id;
  if not found then return 'missing'; end if;
  if v.do_not_contact then return 'do_not_contact'; end if;
  if v.email is null or v.email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then return 'no_email'; end if;
  insert into public.candidate_emails (application_id, candidate_id, company_id, kind, email_to, reply_to, data, offer_id, created_by)
  values (v.application_id, v.candidate_id, v.company_id, p_kind, v.email, v.hr_notification_email,
          app.offer_email_data(p_offer_id), p_offer_id, app.current_person_id())
  on conflict do nothing;
  return case when found then 'queued' else 'already' end;
end $$;

create or replace function app.offer_on_extend() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'extended' and old.status is distinct from 'extended' then
    if new.candidate_token is null then
      new.candidate_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    end if;
    new.contract_required := true;
  end if;
  return new;
end $$;
create trigger t4_offer_token before update of status on public.offers
  for each row execute function app.offer_on_extend();

create or replace function app.offer_email_on_extend() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'extended' and old.status is distinct from 'extended'
     and current_setting('app.bulk_import', true) is distinct from 'on' then
    perform app.queue_offer_email(new.id, 'offer');
  end if;
  return new;
end $$;
create trigger t9_offer_email after update of status on public.offers
  for each row execute function app.offer_email_on_extend();

-- --------------------------------------------------- the candidate's page
/** What the candidate's page shows; null when the link is not (or no longer) good. Server only. */
create or replace function public.offer_for_candidate(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'status', o.status, 'candidate', c.full_name, 'job', coalesce(j.title, 'the role'), 'company', co.name,
    'salary', o.terms->>'salary', 'currency', o.terms->>'currency', 'pay_basis', pb.label,
    'employment_type', et.label, 'start_date', o.terms->>'start_date', 'notes', o.terms->>'notes',
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

/** The candidate answers through their link. Server only. */
create or replace function public.answer_offer_by_token(p_token text, p_answer text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_offer public.offers;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_title text;
  v_to uuid;
begin
  if p_answer not in ('accepted', 'declined') then
    raise exception 'Accept or decline the offer.' using errcode = '22023';
  end if;
  select * into v_offer from public.offers
   where p_token is not null and length(p_token) = 64 and candidate_token = p_token for update;
  if not found then
    raise exception 'This offer link is not valid.' using errcode = 'P0002';
  end if;
  if v_offer.status <> 'extended' then
    raise exception 'This offer has already been answered or withdrawn.' using errcode = '22023';
  end if;
  if v_offer.expires_on is not null and v_offer.expires_on < current_date then
    raise exception 'This offer expired on %. Please contact us.', to_char(v_offer.expires_on, 'DD Mon YYYY') using errcode = '22023';
  end if;
  if p_answer = 'declined' and v_reason is null then
    raise exception 'Tell us why you are declining — it helps us.' using errcode = '22023';
  end if;
  if length(coalesce(v_reason, '')) > 2000 then
    raise exception 'Keep the reason to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  update public.offers
     set status = p_answer, answered_by_candidate_at = now(),
         accepted_at = case when p_answer = 'accepted' then now() else accepted_at end,
         decline_reason = case when p_answer = 'declined' then v_reason else decline_reason end
   where id = v_offer.id;
  update public.approval_tasks set status = 'superseded'
   where subject_type = 'offer' and subject_id = v_offer.id and status = 'open';

  select c.full_name || coalesce(' · ' || j.title, '') into v_title
    from public.applications a join public.candidates c on c.id = a.candidate_id
    left join public.jobs j on j.id = a.job_id where a.id = v_offer.application_id;
  for v_to in
    select x from (select v_offer.created_by as x
                   union select h from app.approvers_or_contacts(v_offer.company_id, 'offer.approve') h) s
     where x is not null
  loop
    perform app.notify(v_to, v_offer.company_id, 'offer.answered',
      case when p_answer = 'accepted' then 'Offer accepted: ' else 'Offer declined: ' end || coalesce(v_title, 'candidate'),
      case when p_answer = 'accepted'
           then 'Upload the signed contract and run any checks, then confirm the hire.'
           else 'Reason: ' || v_reason || ' · consider the next-ranked candidate.' end,
      '/hiring/applications/' || v_offer.application_id, 'offer', v_offer.id,
      'offer.answered:' || v_offer.id, true);
  end loop;
  return jsonb_build_object('status', p_answer);
end $$;

revoke execute on function public.offer_for_candidate(text), public.answer_offer_by_token(text, text, text)
  from public, anon, authenticated;
grant execute on function public.offer_for_candidate(text), public.answer_offer_by_token(text, text, text) to service_role;

-- ------------------------------------------------ the signed contract (6.6)
create or replace function public.record_signed_contract(p_offer_id uuid, p_file_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_offer public.offers;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_offer from public.offers where id = p_offer_id for update;
  if not found then
    raise exception 'That offer no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_offer.company_id, 'candidates.review') then
    raise exception 'You need "Record interview feedback" in this company.' using errcode = '42501';
  end if;
  if v_offer.status <> 'accepted' then
    raise exception 'The signed contract is recorded once the offer is accepted.' using errcode = '22023';
  end if;
  if p_file_id is not null and not exists (select 1 from public.application_files f
                                            where f.id = p_file_id and f.application_id = v_offer.application_id) then
    raise exception 'Pick one of this application''s files.' using errcode = '22023';
  end if;
  update public.offers
     set contract_file_id = p_file_id,
         contract_recorded_by = case when p_file_id is null then null else app.current_person_id() end,
         contract_recorded_at = case when p_file_id is null then null else now() end
   where id = p_offer_id;
  return jsonb_build_object('contract_file_id', p_file_id);
end $$;
grant execute on function public.record_signed_contract(uuid, uuid) to authenticated;

create or replace function app.guard_hire_contract() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if new.stage_key = 'hired' and old.stage_key is distinct from 'hired'
     and exists (select 1 from public.offers o
                  where o.application_id = new.id and o.status = 'accepted'
                    and o.contract_required and o.contract_file_id is null) then
    raise exception 'Record the signed contract on the offer before confirming the hire.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger t4_hire_contract before update of stage_key on public.applications
  for each row execute function app.guard_hire_contract();

-- ---------------------------------------------------- the clocks, again
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
  loop
    -- 8.7: the candidate first, once, while the offer is still open.
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

  return jsonb_build_object('offers', v_offers, 'first_response', v_first);
end $$;
revoke execute on function public.run_hiring_clocks() from public, anon, authenticated;
grant execute on function public.run_hiring_clocks() to service_role;

commit;
