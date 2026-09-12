-- 0029_leave_certificates.sql
-- Leave flows parity with Field Notebook (plan 039):
--  * a sick-leave request that needs a certificate and has none yet opens the
--    person's self-upload window for medical_certificate (insert only — the
--    delete window of 0021 stays tied to HR document requests);
--  * request preview: what these dates could still draw, computed by the
--    same arithmetic request_leave uses (carry-over by window, pending
--    reserved), so the form never disagrees with the refusal.

create or replace function app.has_open_leave_certificate(person uuid, company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leave_requests lr
                 where lr.person_id = person and lr.company_id = company
                   and lr.requires_document and lr.status in ('pending', 'approved')
                   and not exists (select 1 from public.leave_request_documents d where d.request_id = lr.id))
$$;
grant execute on function app.has_open_leave_certificate(uuid, uuid) to authenticated;

-- The documents row: an HR request, or a certificate the leave needs.
create or replace function app.has_open_document_request(person uuid, company uuid, category text) returns boolean
language sql stable security definer set search_path = public as $$
  select person = app.current_person_id()
     and (exists (select 1 from public.document_requests r
                  where r.person_id = person and r.company_id = company and r.category_key = category
                    and r.status in ('pending', 'needs_correction'))
          or (category = 'medical_certificate' and app.has_open_leave_certificate(person, company)))
$$;

-- The storage object: a separate insert policy, so nothing else widens.
create or replace function app.self_certificate_window(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select split_part(object_name, '/', 2) = app.current_person_id()::text
     and app.has_open_leave_certificate(app.current_person_id(), app.document_object_company(object_name))
$$;
grant execute on function app.self_certificate_window(text) to authenticated;

create policy "employee documents: leave certificate upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'employee-documents' and app.self_certificate_window(name));

-- ------------------------------------------------------- request preview
create or replace function public.requestable_leave(p_person_id uuid, p_company_id uuid, p_start date, p_end date) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if v_me <> p_person_id and not app.has_capability(p_company_id, 'leave.approve') and not app.has_capability(p_company_id, 'leave.view') then
    raise exception 'Viewing this balance needs leave.view in the company.' using errcode = '42501';
  end if;
  select ep.* into v_period from public.employment_periods ep
    join public.employment_statuses es on es.key = ep.status and es.counts_as_employed
    where ep.person_id = p_person_id and ep.company_id = p_company_id
    order by ep.start_date desc limit 1;
  if not found then return 0; end if;
  return app.requestable_leave(p_person_id, p_company_id, p_start, p_end, app.employment_country(v_period.id));
end $$;
grant execute on function public.requestable_leave(uuid, uuid, date, date) to authenticated;
