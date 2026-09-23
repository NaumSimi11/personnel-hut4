-- Delete a mistaken/test application from its job, including its stage history.
-- Candidate and employment records are independent and must survive.
create or replace function public.delete_job_application(p_application_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_app public.applications%rowtype;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_app from public.applications where id = p_application_id for update;
  if not found then
    raise exception 'That application no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_app.company_id, 'candidates.review') then
    raise exception 'You cannot delete applications in this company.' using errcode = '42501';
  end if;
  -- Files need storage cleanup; interview feedback and offers have their own
  -- workflows. Do not silently cascade these away from the job list.
  if exists (select 1 from public.application_files where application_id = v_app.id)
     or exists (select 1 from public.interviews where application_id = v_app.id)
     or exists (select 1 from public.offers where application_id = v_app.id) then
    raise exception 'This application has files, interviews or offers. Remove those records before deleting the application.'
      using errcode = '22023';
  end if;
  -- application_events cascade; the existing audit trigger records deletion.
  delete from public.applications where id = v_app.id;
  return jsonb_build_object('deleted', true);
end $$;

revoke all on function public.delete_job_application(uuid) from public, anon;
grant execute on function public.delete_job_application(uuid) to authenticated;
