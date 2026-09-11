-- 0012_job_workspace.sql
-- The job workspace (plan 017): promotion is a state machine with separated
-- duties, and the recruitment audit trail is readable by the people who work
-- the job. Tables and capabilities already exist (0003, 0007); this migration
-- only adds enforcement.

-- ------------------------------------------------------------- promotions
-- Who wrote the copy — needed to refuse self-review.
alter table public.promotions
  add column drafted_by uuid references public.people(id);

-- Status moves only through advance_promotion. Inserting the request stays
-- open to jobs.edit holders (the brief snapshot is theirs to write); deleting
-- is not a workflow step and stays closed.
drop policy if exists write on public.promotions;
create policy ins on public.promotions for insert to authenticated
  with check (app.has_capability(company_id, 'jobs.edit'));

-- The transition table (plan 017):
--   requested | changes_requested | draft  → draft             marketing.draft, copy required
--   draft                                  → in_review         marketing.draft
--   in_review                              → approved          marketing.approve, not the drafter
--   in_review                              → changes_requested marketing.approve, not the drafter
--   approved                               → published         marketing.publish, URL required
--   any non-terminal                       → cancelled         jobs.edit
--   cancelled                              → requested         jobs.edit, fresh brief, clean slate
drop function if exists public.advance_promotion(uuid, text, text, text);
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
      if v_promo.drafted_by = v_me then
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

revoke all on function public.advance_promotion(uuid, text, text, text, jsonb) from public, anon;
grant execute on function public.advance_promotion(uuid, text, text, text, jsonb) to authenticated, service_role;

-- ------------------------------------------------------------ activity trail
-- The Activity tab: people who can see a job can see what happened to it and
-- its channels and promotions; application and offer rows carry candidate
-- workflow state and follow candidates.view. The admin / access.manage policy
-- from 0006 stays for everything else.
create policy sel_recruitment on public.activity_log for select to authenticated
  using (company_id is not null and (
    (entity_type in ('jobs', 'job_channels', 'promotions')
      and app.has_capability(company_id, 'jobs.view'))
    or (entity_type in ('applications', 'offers')
      and app.has_capability(company_id, 'candidates.view'))
  ));

-- The trail names its actors: a real FK (nullable, set null on delete so the
-- log never blocks removing a person) lets the app embed the name.
alter table public.activity_log
  add constraint activity_log_actor_person_id_fkey
  foreign key (actor_person_id) references public.people(id) on delete set null;
