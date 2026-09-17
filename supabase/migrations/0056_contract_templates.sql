-- 0056_contract_templates.sql
-- Contracts written once, filled in per person, printed, signed, filed back.
--
-- The app already had every part of this except the template: document
-- categories name an employment_agreement and an amendment, generated_documents
-- renders PDFs, and documents keeps a generated form as version 1 and the
-- signed scan somebody uploads as version 2. What was missing was the body — so
-- contracts lived in somebody's Word folder and reached the app only as a scan,
-- if at all.
--
-- A template is a body with {{placeholders}} standing for that person's facts.
-- Rendering refuses when a required one has no value, and leaves an unfilled
-- placeholder visible rather than blank: "a monthly salary of  MKD" is a
-- document people sign without reading twice, and a visible {{salary}} is not.
--
-- Signing stays on paper. These are employment contracts, and the in-app
-- signature added in 0053 is a SIMPLE electronic signature — right for handing
-- a laptop back, not enough for a contract under EU/MK rules, which want a
-- qualified signature from an accredited provider. So the app prints, the
-- parties sign by hand, and the scan comes back as version 2. That is the
-- maintainer's decision and it is the conservative one.

create table public.contract_templates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id),   -- NULL = the whole holding
  category_key text not null references public.document_categories(key),
  title text not null,
  body text not null,
  version int not null default 1,
  status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  published_at timestamptz,
  published_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index contract_templates_company_idx on public.contract_templates (company_id, status);
create trigger touch before update on public.contract_templates
  for each row execute function app.touch_updated_at();

alter table public.contract_templates enable row level security;

-- A template is not a person's record: anyone who may see a company may read
-- its templates, and the holding's are readable by everyone signed in.
create policy sel on public.contract_templates for select to authenticated
  using (company_id is null or app.in_company(company_id));

-- Writing one is an HR act, so it takes the capability that governs employment
-- paperwork in that company. The holding's own templates are admin-only,
-- because they are the default every company inherits.
create policy ins on public.contract_templates for insert to authenticated
  with check (case when company_id is null then app.is_admin()
                   else app.has_capability(company_id, 'employment.edit') end);
create policy upd on public.contract_templates for update to authenticated
  using (case when company_id is null then app.is_admin()
              else app.has_capability(company_id, 'employment.edit') end)
  with check (case when company_id is null then app.is_admin()
                   else app.has_capability(company_id, 'employment.edit') end);
create policy del on public.contract_templates for delete to authenticated
  using (case when company_id is null then app.is_admin()
              else app.has_capability(company_id, 'employment.edit') end);

-- Publishing a template is what makes it usable, and a published one is never
-- edited in place: a contract issued last month must still be explicable by the
-- text that produced it, so a change makes a new version and archives the old.
create or replace function public.publish_contract_template(
  p_template_id uuid, p_body text default null, p_title text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.contract_templates; v_body text; v_new uuid;
begin
  select * into t from public.contract_templates where id = p_template_id for update;
  if not found then raise exception 'Template not found.'; end if;
  if not (case when t.company_id is null then app.is_admin()
               else app.has_capability(t.company_id, 'employment.edit') end) then
    raise exception 'You may not publish templates for this company.' using errcode = '42501';
  end if;
  v_body := coalesce(nullif(btrim(coalesce(p_body, '')), ''), t.body);
  if btrim(v_body) = '' then
    raise exception 'A template needs a body before it can be published.';
  end if;

  if t.status = 'published' then
    -- A published template earns a new version rather than being rewritten.
    update public.contract_templates set status = 'archived' where id = t.id;
    insert into public.contract_templates
        (company_id, category_key, title, body, version, status, published_at, published_by)
      values (t.company_id, t.category_key, coalesce(nullif(btrim(coalesce(p_title, '')), ''), t.title),
              v_body, t.version + 1, 'published', now(), app.current_person_id())
      returning id into v_new;
    return jsonb_build_object('template_id', v_new, 'version', t.version + 1);
  end if;

  update public.contract_templates
    set body = v_body, title = coalesce(nullif(btrim(coalesce(p_title, '')), ''), title),
        status = 'published', published_at = now(), published_by = app.current_person_id()
    where id = t.id;
  return jsonb_build_object('template_id', t.id, 'version', t.version);
end $$;
grant execute on function public.publish_contract_template(uuid, text, text) to authenticated;

comment on table public.contract_templates is
  'Contract bodies with {{placeholders}}. Published versions are never edited — a change makes a new version.';
