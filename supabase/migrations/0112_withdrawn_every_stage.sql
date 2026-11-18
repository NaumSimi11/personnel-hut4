-- 0112: withdrawn at every stage, and a rejection at Offer (board card B1).
--
-- A status belongs to one stage, and set_application_status moves the
-- application to its status's stage. "withdrawn" lived only under Interview,
-- so a candidate who withdrew during Screening was moved forward to
-- Interview; Offer had no rejection at all, so rejecting at Offer moved the
-- application back to Interview.
--
-- Three statuses, keyed per stage because a key names one stage. Labels
-- follow 0098's rule: label = key until HR renames them under Hiring →
-- Labels (a label is unique per stage only, so "withdrawn" is free at
-- Screening and Offer). The Interview "withdrawn" and its rows stay.

insert into public.application_sub_statuses (key, stage_key, label, sort_order, outcome) values
  ('withdrawn_screening', 'screening', 'withdrawn_screening', 90, 'withdrew'),
  ('rejected_at_offer',   'offer',     'rejected_at_offer',   30, 'rejected'),
  ('withdrawn_offer',     'offer',     'withdrawn_offer',     40, 'withdrew')
on conflict (key) do nothing;
