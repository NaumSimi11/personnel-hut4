-- 0046_offer_self_approval.sql
-- The person who drafted an offer may now approve it.
--
-- Plan 018b split the two roles on purpose: an offer carries a salary, and
-- "approved by someone other than the author" is the control an auditor looks
-- for. advance_offer enforced it (0014), refusing with "The person who drafted
-- the offer cannot approve it."
--
-- The holding asked for it to be dropped (September 2026), for a practical
-- reason: a company of this size often has exactly one person holding
-- offer.approve, so the rule did not buy a second pair of eyes — it stopped the
-- offer moving at all, and the work went around the app instead of through it.
-- A control people route around protects nothing.
--
-- What is unchanged, and matters if this is ever revisited:
--   * offer.approve is still required. This widens WHO may approve, not
--     whether approval happens at all.
--   * offers.approved_by still records the approver, so an offer approved by
--     its own author is plainly visible in the record — the fact is kept even
--     though it is no longer prevented.
--   * Every other transition, message and return value is byte-identical to
--     0014. This function is that text with three lines removed.
--
-- To restore the control, put those three lines back in the 'approved' branch.

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
      -- The author may approve their own offer (this migration, 0046).
      -- approved_by below is what records that they did.
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
