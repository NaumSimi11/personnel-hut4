-- 0116: offers are approved by HR only, with no salary band check (decision D4).
--
-- 0104 compared an offer's salary with its request's band: inside went to
-- HR, outside to HR, Finance and the Director. D4 removes the band check
-- from the offer step, so every offer takes the one offer route — HR by
-- default ("offer_in_band", which the settings now simply call "Offers").
-- advance_offer routes on app.offer_band, so the check is retired there:
-- it answers "in band" without a verdict, and no band note is written.
-- The request's band itself stays (a request still names one).

create or replace function app.offer_band(p_offer_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('in_band', true, 'note', null)
$$;
