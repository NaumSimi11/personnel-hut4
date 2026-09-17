-- 0047_asset_inventory_number.sql
-- Two things an asset carries that the register had nowhere to put.
--
--   1. inventory_number — Инв. бр., the number the accounts key their fixed
--      assets on. It is NOT the same as asset_tag (Шифра): both are printed on
--      the physical barcode label, and a попис is reconciled against the
--      accounting records by this number. The first import dropped it for all
--      191 assets because the parser read columns by position and never looked
--      at column six.
--
--   2. holder_note — who the source says holds the asset, when that cannot be
--      resolved to a person in this system. "Naumche Simidjioski" is the same
--      man as "Naum Simidjioski"; "office" and "office Struga" are places, not
--      people; "IL" is initials. The importer is right to refuse to invent a
--      person_id from those — but the register was then showing the asset as
--      sitting in magacin, available to hand out, when the books say someone
--      has it. That is worse than saying nothing. The text goes here so the
--      register can tell the truth: held, by this name, not yet matched.
--
-- Neither column is authoritative over asset_assignments. A real assignment
-- always wins; holder_note is what is displayed in its absence.

alter table public.assets add column if not exists inventory_number text;
alter table public.assets add column if not exists holder_note text;

comment on column public.assets.inventory_number is
  'Инв. бр. — the accounting inventory number, printed on the label beside asset_tag.';
comment on column public.assets.holder_note is
  'Who the source says holds this, when it resolves to no person. Never overrides an assignment.';

create index if not exists assets_inventory_number_idx
  on public.assets (inventory_number) where inventory_number is not null;
