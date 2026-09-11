-- 0011_company_profile.sql
-- A company becomes a real entity, not just a name and a code (blueprint §2:
-- the overview shows identity, HR contact and director; branding is a
-- per-company override). Facts that documents and payroll exports need are
-- typed columns with constraints; the flexible, purely presentational part
-- (logo, accent colour, tagline) lives in the brand jsonb reserved in 0001.
--
-- Authorization is unchanged: companies stay readable by every signed-in
-- user and writable by platform admins only (0006 admin_write policy).

alter table public.companies
  add column legal_name text,
  add column registration_number text,
  add column tax_id text,
  add column address_line1 text,
  add column address_line2 text,
  add column city text,
  add column postcode text,
  add column country text,
  add column website text,
  add column contact_email text,
  add column contact_phone text,
  add column director_person_id uuid references public.people(id),
  add column hr_contact_person_id uuid references public.people(id);

-- brand = { logo_path?, accent_color?, tagline? }. The colour is validated
-- here so a bad value can never reach a style attribute.
alter table public.companies
  add constraint companies_brand_is_object check (jsonb_typeof(brand) = 'object'),
  add constraint companies_brand_accent_hex check (
    brand->>'accent_color' is null or brand->>'accent_color' ~ '^#[0-9a-fA-F]{6}$'
  );

create index companies_director_idx on public.companies (director_person_id);
create index companies_hr_contact_idx on public.companies (hr_contact_person_id);

-- --------------------------------------------------------------- logo bucket
-- Logos are public by nature (careers pages, offer letters) — a public bucket
-- served without signing. Writes mirror the companies table: admins only.
-- Objects live at {company_id}/logo.{ext}.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('company-logos', 'company-logos', true, 1048576,
        array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'])
on conflict (id) do nothing;

create policy "company logos: public read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'company-logos');
create policy "company logos: admin insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'company-logos' and app.is_admin());
create policy "company logos: admin update" on storage.objects
  for update to authenticated
  using (bucket_id = 'company-logos' and app.is_admin())
  with check (bucket_id = 'company-logos' and app.is_admin());
create policy "company logos: admin delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'company-logos' and app.is_admin());
