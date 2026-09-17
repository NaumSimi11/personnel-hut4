-- 0045_popis_register.sql
-- Попис slice 1: the register the annual count will confirm.
--   1. Two asset types the holding's spreadsheet already uses and the app
--      did not have: Desktop PC and Возила (vehicles). Софтвери maps to the
--      existing software_license, which is already is_physical = false —
--      a licence cannot be seen on a desk, so the count reads it as a
--      documentary check rather than a physical one.
--   2. companies.legal_name: the registered name ("СИНАМИ ДООЕЛ Скопје"),
--      which the попис report must print in its header. The display name
--      ("Synami") is what the app shows everywhere else; a report signed by
--      a commission needs the name on the company's registration. Nullable,
--      and the report falls back to the display name until it is filled in.

insert into public.asset_types (key, label, is_physical) values
  ('desktop', 'Desktop PC', true),
  ('vehicle', 'Vehicles', true)
on conflict (key) do nothing;

alter table public.companies add column if not exists legal_name text;
