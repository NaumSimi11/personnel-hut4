-- 0048_asset_ordinal.sql
-- ред. бр. — the row number the equipment lists are kept by.
--
-- The register now carries every column the companies actually use:
--   ред. бр.          → ordinal            (this migration)
--   Шифра             → asset_tag
--   Основно средство  → model
--   Корисник          → an assignment, or holder_note when it is not a person
--   Забелешка         → note
--   Инв. бр.          → inventory_number   (0047)
--
-- Nullable, because the sheets disagree: Synami numbers its rows, Hut 4 does
-- not, and Liquiditas has no such column at all. A company that does not keep
-- one leaves it empty rather than having a number invented for it.

alter table public.assets add column if not exists ordinal integer;

comment on column public.assets.ordinal is
  'ред. бр. — the row number in the company''s own equipment list. Empty where a company does not keep one.';

create index if not exists assets_ordinal_idx
  on public.assets (company_id, ordinal) where ordinal is not null;
