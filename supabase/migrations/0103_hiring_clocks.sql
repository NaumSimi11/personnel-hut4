-- 0103_hiring_clocks.sql
-- Clocks that run out (Hiring Module user flows, 11 Nov 2026: 6.4, 8.5, 8.7).
-- The spec leaves the times open (10.8); these are the defaults, in one place.
--
--   * Offer expiry (6.4): an offer sent to the candidate ("extended") gets an
--     expiry date, a week out unless HR sets another. Two days before it the
--     offer's author is reminded; once it passes, told it expired.
--   * First response (8.5): somebody who applied through the careers page
--     and is still "sourced" (nobody has reached out) three days later — the
--     application's owner is alerted, or the company's HR contact when it has
--     no owner. Imported history is left alone: only applications made in
--     PeopleOS in the last 30 days count.
--
-- Nothing in PeopleOS runs on a timer. `run_hiring_clocks` is called by the
-- server each time it delivers notifications (every sign-in and most
-- actions), and every alert is deduplicated, so calling it often is harmless.

begin;

alter table public.offers add column expires_on date;

create or replace function app.offer_expiry_default() returns trigger
language plpgsql as $$
begin
  if new.status = 'extended' and old.status is distinct from 'extended' and new.expires_on is null then
    new.expires_on := current_date + 7;
  end if;
  return new;
end $$;
create trigger t3_expiry_default before update of status on public.offers
  for each row execute function app.offer_expiry_default();

/** HR moves the expiry date of a sent or approved offer. */
create or replace function public.set_offer_expiry(p_offer_id uuid, p_expires_on date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_offer record;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select id, company_id, status into v_offer from public.offers where id = p_offer_id;
  if not found then
    raise exception 'That offer no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_offer.company_id, 'candidates.review') then
    raise exception 'You need "Record interview feedback" in this company to change the offer.' using errcode = '42501';
  end if;
  if v_offer.status not in ('approved', 'extended') then
    raise exception 'Only an approved or sent offer has an expiry date.' using errcode = '22023';
  end if;
  if p_expires_on is null or p_expires_on < current_date then
    raise exception 'Pick an expiry date from today on.' using errcode = '22023';
  end if;
  update public.offers set expires_on = p_expires_on where id = p_offer_id;
  return jsonb_build_object('expires_on', p_expires_on);
end $$;
grant execute on function public.set_offer_expiry(uuid, date) to authenticated;

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
  -- 6.4 / 8.7: offers waiting on the candidate.
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

  -- 8.5: first response to a new application.
  for v in
    select a.id, a.company_id, a.owner_id, a.received_at, c.full_name, j.title, co.hr_contact_person_id
      from public.applications a
      join public.candidates c on c.id = a.candidate_id
      join public.companies co on co.id = a.company_id
      left join public.jobs j on j.id = a.job_id
     where a.source_key = 'careers_page'
       and a.provider_ref is null
       and a.stage_key = 'screening' and a.sub_status_key = 'sourced'
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
