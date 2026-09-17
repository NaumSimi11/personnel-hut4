-- 0045_popis_register.sql
-- Попис slice 1: the register the annual count will confirm.
--   1. Two asset types the holding's spreadsheet already uses and the app
--      did not have: Desktop PC and Возила (vehicles). Софтвери maps to the
--      existing software_license, which is already is_physical = false —
--      a licence cannot be seen on a desk, so the count reads it as a
--      documentary check rather than a physical one.
--   2. companies.legal_name is NOT added here: 0011_company_profile.sql
--      already added it, and 0042's handover form already prints it. The
--      guarded ALTER below is a no-op kept for the record — this migration
--      has been applied, so its SQL must not change. What the column is for:
--      the registered name ("СИНАМИ ДООЕЛ Скопје") that the попис report
--      prints in its header, where the display name ("Synami") the app shows
--      everywhere else would not do for a document a commission signs. It is
--      nullable, and the report falls back to the display name until filled.

insert into public.asset_types (key, label, is_physical) values
  ('desktop', 'Desktop PC', true),
  ('vehicle', 'Vehicles', true)
on conflict (key) do nothing;

alter table public.companies add column if not exists legal_name text;
