-- 0020_hardening_2.sql
-- Second review round (plan 027):
--   1. Offers and promotions could be inserted directly in a non-initial
--      state, bypassing advance_offer / advance_promotion. Inserts are now
--      pinned to the initial state with workflow fields cleared.
--   2. advance_promotion compares drafted_by null-safely (defensive; the
--      old "=" could not match a null drafter either — the real bypass was 1).
--   3. Approving a future-dated compensation change flipped the record in
--      force to 'superseded' at once, dropping the person from payroll until
--      the new date. A closed record now stays 'approved' with an end date;
--      "superseded" is a reading of the dates, not a status.
--   4. apply_due_employment_changes applied every company's changes on any
--      caller's behalf; it now applies only where the caller may edit
--      employment (admins and the service role: everywhere).
--   5. Direct updates to employment_periods.manager_id skipped the loop
--      guard; a trigger now runs it.
--   6. application_files audited unredacted (extracted text, file names).

-- ------------------------------------------------------- 1. pinned inserts
create or replace function app.pin_offer_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;   -- service role / seeds
  new.status := 'draft';
  new.approved_by := null;
  new.accepted_at := null;
  new.extended_at := null;
  new.decline_reason := null;
  return new;
end $$;
create trigger t0_pin_insert before insert on public.offers
  for each row execute function app.pin_offer_insert();

create or replace function app.pin_promotion_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  new.status := 'requested';
  new.copy := null;
  new.publication_url := null;
  new.drafted_by := null;
  new.reviewed_by := null;
  new.published_by := null;
  new.requested_by := app.current_person_id();
  return new;
end $$;
create trigger t0_pin_insert before insert on public.promotions
  for each row execute function app.pin_promotion_insert();

-- ------------------------------------------------- 2. null-safe self-review
create or replace function public.advance_promotion(
  p_promotion_id uuid,
  p_to_status text,
  p_copy text default null,
  p_publication_url text default null,
  p_brief jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_promo record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  select * into v_promo from public.promotions where id = p_promotion_id for update;
  if not found then
    raise exception 'Promotion not found.';
  end if;
  if v_promo.status = 'published' or (v_promo.status = 'cancelled' and p_to_status <> 'requested') then
    raise exception 'This promotion is already %.', replace(v_promo.status, '_', ' ');
  end if;

  case p_to_status
    when 'draft' then
      if v_promo.status not in ('requested', 'changes_requested', 'draft') then
        raise exception 'A draft can only follow a request or a change request.';
      end if;
      if not app.has_capability(v_promo.company_id, 'marketing.draft') then
        raise exception 'Drafting requires marketing.draft in this company.' using errcode = '42501';
      end if;
      if p_copy is null or length(trim(p_copy)) = 0 then
        raise exception 'Write the copy before saving a draft.';
      end if;
      update public.promotions
        set status = 'draft', copy = p_copy, drafted_by = v_me
        where id = p_promotion_id;

    when 'in_review' then
      if v_promo.status <> 'draft' then
        raise exception 'Only a draft can be submitted for review.';
      end if;
      if not app.has_capability(v_promo.company_id, 'marketing.draft') then
        raise exception 'Submitting for review requires marketing.draft in this company.'
          using errcode = '42501';
      end if;
      -- Rewriting the copy on submit makes the submitter the drafter, so the
      -- separation of duties below cannot be sidestepped.
      update public.promotions
        set status = 'in_review',
            copy = coalesce(nullif(trim(p_copy), ''), copy),
            drafted_by = case
              when nullif(trim(p_copy), '') is not null and p_copy is distinct from copy then v_me
              else drafted_by end
        where id = p_promotion_id;

    when 'approved', 'changes_requested' then
      if v_promo.status <> 'in_review' then
        raise exception 'Only content in review can be approved or sent back.';
      end if;
      if not app.has_capability(v_promo.company_id, 'marketing.approve') then
        raise exception 'Reviewing requires marketing.approve in this company.' using errcode = '42501';
      end if;
      if v_promo.drafted_by is not distinct from v_me then
        raise exception 'The person who drafted the content cannot review it.' using errcode = '42501';
      end if;
      update public.promotions
        set status = p_to_status, reviewed_by = v_me
        where id = p_promotion_id;

    when 'published' then
      if v_promo.status <> 'approved' then
        raise exception 'Only approved content can be published.';
      end if;
      if not app.has_capability(v_promo.company_id, 'marketing.publish') then
        raise exception 'Publishing requires marketing.publish in this company.' using errcode = '42501';
      end if;
      if p_publication_url is null or p_publication_url !~ '^https?://' then
        raise exception 'Record the published post''s URL (https://…).';
      end if;
      update public.promotions
        set status = 'published', publication_url = p_publication_url, published_by = v_me
        where id = p_promotion_id;

    when 'cancelled' then
      if not app.has_capability(v_promo.company_id, 'jobs.edit') then
        raise exception 'Cancelling a promotion requires jobs.edit in this company.'
          using errcode = '42501';
      end if;
      update public.promotions set status = 'cancelled' where id = p_promotion_id;

    when 'requested' then
      if v_promo.status <> 'cancelled' then
        raise exception 'Only a cancelled promotion can be requested again.';
      end if;
      if not app.has_capability(v_promo.company_id, 'jobs.edit') then
        raise exception 'Requesting a promotion requires jobs.edit in this company.'
          using errcode = '42501';
      end if;
      update public.promotions
        set status = 'requested', brief = coalesce(p_brief, brief), copy = null,
            drafted_by = null, reviewed_by = null, published_by = null,
            publication_url = null, requested_by = v_me
        where id = p_promotion_id;

    else
      raise exception 'Unknown promotion status: %', p_to_status;
  end case;

  return jsonb_build_object('status', p_to_status);
end $$;

-- ------------------------------------- 3. a closed record stays approved
create or replace function public.decide_compensation(
  p_record_id uuid,
  p_decision text,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_record record;
  v_period record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_record from public.compensation_records where id = p_record_id for update;
  if not found then
    raise exception 'Compensation record not found.';
  end if;
  select * into v_period from public.employment_periods where id = v_record.employment_period_id;
  if not app.has_capability(v_period.company_id, 'salary.approve') then
    raise exception 'Deciding compensation requires salary.approve in this company.' using errcode = '42501';
  end if;
  if v_record.status <> 'proposed' then
    raise exception 'This proposal has already been decided.';
  end if;
  if v_record.proposed_by is not distinct from v_me then
    raise exception 'The person who proposed a change cannot approve it.' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Unknown decision: %', p_decision;
  end if;

  if p_decision = 'rejected' then
    update public.compensation_records
      set status = 'rejected', approved_by = v_me,
          note = case when nullif(trim(coalesce(p_note, '')), '') is null then note
                      else concat_ws(' — ', note, trim(p_note)) end
      where id = p_record_id;
    return jsonb_build_object('status', 'rejected');
  end if;
  -- A proposal left open across a departure can be rejected, never approved.
  if v_period.status = 'former' then
    raise exception 'This employment has ended; the proposal can only be rejected.';
  end if;
  if v_period.end_date is not null and v_record.effective_date > v_period.end_date then
    raise exception 'The effective date (%) is after the employment ends (%); reject and propose again.',
      v_record.effective_date, v_period.end_date;
  end if;
  -- Only the RPC creates approved records and it keeps the newest effective
  -- date last; anything else (a later record written outside it) is refused
  -- rather than left overlapping.
  if exists (select 1 from public.compensation_records
             where employment_period_id = v_record.employment_period_id
               and status = 'approved' and effective_date >= v_record.effective_date) then
    raise exception 'An approved record already starts on or after %.', v_record.effective_date;
  end if;

  -- The record in force stays approved and keeps paying until the day before
  -- the new one starts; only its end date changes.
  update public.compensation_records
    set end_date = v_record.effective_date - 1
    where employment_period_id = v_record.employment_period_id
      and status = 'approved'
      and (end_date is null or end_date >= v_record.effective_date);
  update public.compensation_records
    set status = 'approved', approved_by = v_me,
        note = case when nullif(trim(coalesce(p_note, '')), '') is null then note
                    else concat_ws(' — ', note, trim(p_note)) end
    where id = p_record_id;
  return jsonb_build_object('status', 'approved');
end $$;

-- Records closed under the old rule already carry their end dates.
update public.compensation_records set status = 'approved' where status = 'superseded';

-- ---------------------------------- 4. apply due changes where permitted
create or replace function public.apply_due_employment_changes() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_n int := 0;
begin
  for v_id in
    select c.id from public.employment_changes c
    where c.status = 'scheduled' and c.effective_date <= current_date
      and (auth.uid() is null or app.has_capability(c.company_id, 'employment.edit'))
    order by c.effective_date, c.created_at
  loop
    if app.apply_employment_change(v_id) then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

-- ------------------------------------ 5. loop guard on direct manager edits
create or replace function app.guard_employment_manager() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.manager_id is null or (tg_op = 'UPDATE' and new.manager_id is not distinct from old.manager_id
                                and new.company_id = old.company_id) then
    return new;
  end if;
  if new.manager_id = new.person_id then
    raise exception 'A person cannot be their own manager.';
  end if;
  if app.would_create_cycle(new.person_id, new.manager_id, new.company_id) then
    raise exception 'That would create a circular reporting line: the proposed manager already reports to this person.';
  end if;
  return new;
end $$;
create trigger guard_manager before insert or update on public.employment_periods
  for each row execute function app.guard_employment_manager();

-- ------------------------------------------- 6. redacted file audit
drop trigger if exists audit on public.application_files;
create trigger audit after insert or update or delete on public.application_files
  for each row execute function app.audit_redacted('extracted_text,original_name');
update public.activity_log
  set before = before - array['extracted_text', 'original_name'],
      after = after - array['extracted_text', 'original_name']
  where entity_type = 'application_files';

-- ------------------------------------------- 7. company website is a web URL
-- The careers page renders it as a link for anonymous visitors; the form
-- already insists on http(s), this closes the direct-API path.
alter table public.companies
  add constraint companies_website_url check (website is null or website ~* '^https?://');

-- --------------------------------------- 8. a scheduler for due changes
-- With apply_due scoped to editors, changes must not wait for one of them to
-- open a page: pg_cron runs it nightly as the system (auth.uid() is null, so
-- every company is covered and the audit trail shows no false actor). The
-- extension is absent from the local verification shim, hence the guard.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'apply-due-employment-changes';
    perform cron.schedule('apply-due-employment-changes', '15 0 * * *',
      $job$ select public.apply_due_employment_changes() $job$);
  end if;
end $$;
