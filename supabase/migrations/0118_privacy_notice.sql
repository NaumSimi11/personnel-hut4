-- 0118: a privacy notice beside the email templates (board card C4).
--
-- The notice has to be shown when the data is collected, so it belongs on
-- the careers application form and in the "Application received" email.
-- HR keeps it with the email wording (0109): kind "privacy_notice", the
-- subject its heading, the body the lawyer's text — holding-wide, or per
-- company where the wording differs by country. The careers form shows it
-- above the consent box; the received email carries it at the end.

alter table public.email_templates drop constraint email_templates_kind_check;
alter table public.email_templates add constraint email_templates_kind_check
  check (kind in ('received', 'rejected', 'withdrawn', 'offer', 'offer_reminder', 'privacy_notice'));
