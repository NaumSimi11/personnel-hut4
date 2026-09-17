-- 0049_asset_type_other.sql
-- "Other", with room to say what the thing actually is.
--
-- The type list is a fixed table — laptop, monitor, phone, desktop, vehicle,
-- software_license, accessory — so anything that is none of those had to be
-- filed as an accessory, and the register then called a docking station an
-- accessory and left it at that. The companies' own lists have always had a
-- Останати / Останато column for exactly this.
--
-- type_note is what the thing is when the type is 'other'. It is the same
-- bargain as holder_note (0047): the register would rather print what someone
-- wrote than print a category everybody knows is wrong.
--
-- This deliberately does NOT let anyone invent a new type. A typed note is free
-- text — ten people will write a docking station ten ways, and none of it can be
-- filtered or counted. If a kind of equipment turns out to be common enough to
-- want counting, it should be given a real type here, in a migration, and the
-- notes folded into it.

insert into public.asset_types (key, label, is_physical) values
  ('other', 'Other', true)
on conflict (key) do nothing;

alter table public.assets add column if not exists type_note text;

comment on column public.assets.type_note is
  'What this is, when type_key is ''other''. Free text; not countable. Promote common ones to a real asset_type.';
