-- 0014_interviews_offers.sql
-- Candidate review depth, part two (plan 018b): interviews with blind
-- scorecards, and the offer as a state machine with separated duties.
-- Interview feedback is recruitment data, distinct from employee performance
-- reviews (core plan §9); it lives under candidates.view / candidates.review.

-- --------------------------------------------------------- scorecard criteria
-- [{ id, label, description? }] per job; each scorecard snapshots the labels
-- it rated so later edits never rewrite history.
alter table public.jobs
  add column scorecard_criteria jsonb not null default '[]'::jsonb,
  add constraint jobs_scorecard_criteria_is_array check (jsonb_typeof(scorecard_criteria) = 'array');

-- ----------------------------------------------------------------- interviews
create table public.interviews (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  company_id uuid not null references public.companies(id),  -- derived, never client-trusted
  kind text not null default 'other' check (kind in ('phone', 'technical', 'panel', 'final', 'other')),
  scheduled_at timestamptz not null,
  duration_minutes int not null default 60 check (duration_minutes > 0 and duration_minutes <= 480),
  location text,
  notes text,
  status text not null default 'scheduled' check (status in ('scheduled', 'completed', 'cancelled')),
  created_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index interviews_application_idx on public.interviews (application_id);
create index interviews_company_when_idx on public.interviews (company_id, scheduled_at);
create trigger touch before update on public.interviews
  for each row execute function app.touch_updated_at();

create or replace function app.sync_interview_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select company_id into strict new.company_id
    from public.applications where id = new.application_id;
  return new;
end $$;
create trigger sync_company before insert or update on public.interviews
  for each row execute function app.sync_interview_company();
create trigger audit after insert or update or delete on public.interviews
  for each row execute function app.audit();

-- Who was scheduled to interview. Information, not a gate (maintainer
-- decision): anyone with candidates.review may score.
create table public.interview_panel (
  interview_id uuid not null references public.interviews(id) on delete cascade,
  person_id uuid not null references public.people(id),
  primary key (interview_id, person_id)
);

-- ----------------------------------------------------------------- scorecards
-- ratings: [{ criterion_id, label, rating 1..4, evidence }]
create table public.scorecards (
  id uuid primary key default gen_random_uuid(),
  interview_id uuid not null references public.interviews(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  company_id uuid not null references public.companies(id),  -- derived
  author_id uuid not null references public.people(id),
  ratings jsonb not null default '[]'::jsonb check (jsonb_typeof(ratings) = 'array'),
  recommendation text not null check (recommendation in ('strong_no', 'no', 'yes', 'strong_yes')),
  summary text,
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (interview_id, author_id)
);
create index scorecards_application_idx on public.scorecards (application_id);
create trigger touch before update on public.scorecards
  for each row execute function app.touch_updated_at();

create or replace function app.sync_scorecard_scope() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select i.application_id, i.company_id into strict new.application_id, new.company_id
    from public.interviews i where i.id = new.interview_id;
  return new;
end $$;
create trigger sync_scope before insert or update on public.scorecards
  for each row execute function app.sync_scorecard_scope();
create trigger audit after insert or update or delete on public.scorecards
  for each row execute function app.audit();

-- Blind-rule helpers (SECURITY DEFINER so the scorecards policy can consult
-- interview_panel and scorecards without recursing).
create or replace function app.is_on_panel(interview uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.interview_panel p
                 where p.interview_id = interview and p.person_id = app.current_person_id())
$$;
create or replace function app.has_scored(interview uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.scorecards s
                 where s.interview_id = interview and s.author_id = app.current_person_id())
$$;
grant execute on function app.is_on_panel(uuid), app.has_scored(uuid) to authenticated;

-- ------------------------------------------------------------------------ RLS
alter table public.interviews enable row level security;
create policy sel on public.interviews for select to authenticated
  using (app.has_capability(company_id, 'candidates.view'));
create policy ins on public.interviews for insert to authenticated
  with check (exists (select 1 from public.applications a where a.id = application_id
                      and app.has_capability(a.company_id, 'candidates.review')));
create policy upd on public.interviews for update to authenticated
  using (app.has_capability(company_id, 'candidates.review'))
  with check (app.has_capability(company_id, 'candidates.review'));
create policy del on public.interviews for delete to authenticated
  using (app.has_capability(company_id, 'candidates.review'));

alter table public.interview_panel enable row level security;
create policy sel on public.interview_panel for select to authenticated
  using (exists (select 1 from public.interviews i where i.id = interview_id
                 and app.has_capability(i.company_id, 'candidates.view')));
create policy write on public.interview_panel for all to authenticated
  using (exists (select 1 from public.interviews i where i.id = interview_id
                 and app.has_capability(i.company_id, 'candidates.review')))
  with check (exists (select 1 from public.interviews i where i.id = interview_id
                      and app.has_capability(i.company_id, 'candidates.review')));

alter table public.scorecards enable row level security;
-- The blind rule: your own; or anyone's if you can view candidates here and
-- you are not on this interview's panel; or, if you are, once you have scored.
create policy sel on public.scorecards for select to authenticated
  using (author_id = app.current_person_id()
         or (app.has_capability(company_id, 'candidates.view')
             and (not app.is_on_panel(interview_id) or app.has_scored(interview_id))));
create policy ins on public.scorecards for insert to authenticated
  with check (author_id = app.current_person_id()
              and exists (select 1 from public.interviews i where i.id = interview_id
                          and app.has_capability(i.company_id, 'candidates.review')));
create policy upd on public.scorecards for update to authenticated
  using (author_id = app.current_person_id())
  with check (author_id = app.current_person_id());

grant select, insert, update, delete on public.interviews, public.interview_panel to authenticated;
grant select, insert, update on public.scorecards to authenticated;
grant all on public.interviews, public.interview_panel, public.scorecards to service_role;

-- --------------------------------------------------------------------- offers
alter table public.offers
  add column created_by uuid references public.people(id),
  add column extended_at timestamptz,
  add column decline_reason text;

-- The 0003 gate trigger required offer.approve to extend; advance_offer is now
-- the single transition path (extending needs candidates.review), so it goes.
drop trigger if exists t2_gate_transitions on public.offers;
drop function if exists app.gate_offer_transitions();

-- Authorship comes from the session and never changes: the separation of
-- duties in advance_offer compares against it. The service role (no
-- auth.uid) keeps what it inserts, for seeding.
create or replace function app.set_offer_author() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.created_by := app.current_person_id(); end if;
  else
    new.created_by := old.created_by;
  end if;
  return new;
end $$;
create trigger t1_author before insert or update on public.offers
  for each row execute function app.set_offer_author();

-- Terms are edited while the offer is a draft; status moves only through
-- advance_offer. Reading stays candidates.view (0006).
drop policy if exists write on public.offers;
create policy ins on public.offers for insert to authenticated
  with check (app.has_capability(company_id, 'candidates.review'));
create policy upd_draft on public.offers for update to authenticated
  using (status = 'draft' and app.has_capability(company_id, 'candidates.review'))
  with check (status = 'draft' and app.has_capability(company_id, 'candidates.review'));

-- Transition table (plan 018b):
--   draft        → in_approval   candidates.review
--   in_approval  → approved      offer.approve, not created_by
--   in_approval  → draft         offer.approve (send back)
--   approved     → extended      candidates.review
--   extended     → accepted      candidates.review
--   extended     → declined      candidates.review, reason required
--   non-terminal → withdrawn     candidates.review
create or replace function public.advance_offer(
  p_offer_id uuid,
  p_to_status text,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_offer record;
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
      update public.offers set status = 'in_approval' where id = p_offer_id;

    when 'approved' then
      if v_offer.status <> 'in_approval' then
        raise exception 'Only an offer in approval can be approved.';
      end if;
      if not app.has_capability(v_offer.company_id, 'offer.approve') then
        raise exception 'Approving an offer requires offer.approve in this company.' using errcode = '42501';
      end if;
      if v_offer.created_by is not distinct from v_me then
        raise exception 'The person who drafted the offer cannot approve it.' using errcode = '42501';
      end if;
      update public.offers set status = 'approved', approved_by = v_me where id = p_offer_id;

    when 'draft' then
      if v_offer.status <> 'in_approval' then
        raise exception 'Only an offer in approval can be sent back to draft.';
      end if;
      if not app.has_capability(v_offer.company_id, 'offer.approve') then
        raise exception 'Sending an offer back requires offer.approve in this company.' using errcode = '42501';
      end if;
      update public.offers set status = 'draft', approved_by = null where id = p_offer_id;

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

    else
      raise exception 'Unknown offer status: %', p_to_status;
  end case;

  return jsonb_build_object('status', p_to_status);
end $$;

revoke all on function public.advance_offer(uuid, text, text) from public, anon;
grant execute on function public.advance_offer(uuid, text, text) to authenticated, service_role;
