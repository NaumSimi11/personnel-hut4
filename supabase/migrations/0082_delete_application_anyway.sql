-- 0082_delete_application_anyway.sql
-- Deleting an application that has things attached to it (plan 064).
--
-- 0081 refuses an application with files, interviews or offers, and tells you
-- to "remove those records before deleting the application". There is no way
-- to remove them: nothing in the app deletes an offer or an interview. So that
-- refusal is a dead end, and the leftover test row on live proves it — one
-- file, one interview and one offer, and no way to clear any of them.
--
-- The refusal is still right as a default: an interview is somebody's written
-- opinion of a person and an offer is a number that was sent. Neither should
-- vanish because a list looked untidy. What was missing is a way to say "yes,
-- I mean it", and to be told exactly what that costs before saying it.
--
-- So `p_force`. Off, it behaves exactly as 0081 did. On, it takes the
-- attached records with the application and says in its answer how many of
-- each — which the app shows in the confirmation BEFORE the call, not after.
--
-- The one-argument form is dropped rather than left beside this one: 0043
-- learned that an overload makes the RPC call ambiguous from PostgREST.
drop function if exists public.delete_job_application(uuid);

create or replace function public.delete_job_application(
  p_application_id uuid,
  p_force boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_app public.applications%rowtype;
  v_files int;
  v_interviews int;
  v_offers int;
  v_paths text[];
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

  select count(*) into v_files from public.application_files where application_id = v_app.id;
  select count(*) into v_interviews from public.interviews where application_id = v_app.id;
  select count(*) into v_offers from public.offers where application_id = v_app.id;

  if not coalesce(p_force, false) and (v_files > 0 or v_interviews > 0 or v_offers > 0) then
    raise exception 'This application has files, interviews or offers. Remove those records before deleting the application.'
      using errcode = '22023';
  end if;

  if coalesce(p_force, false) then
    -- The files' objects live in Storage, which SQL cannot reach; the paths go
    -- back to the caller so the app can remove what it just orphaned.
    select coalesce(array_agg(storage_path), '{}') into v_paths
      from public.application_files where application_id = v_app.id;
    -- Scorecards hang off interviews and cascade with them (0003).
    delete from public.offers where application_id = v_app.id;
    delete from public.interviews where application_id = v_app.id;
    delete from public.application_files where application_id = v_app.id;
  end if;

  -- application_events cascade; the existing audit trigger records deletion.
  delete from public.applications where id = v_app.id;
  return jsonb_build_object(
    'deleted', true,
    'files', v_files, 'interviews', v_interviews, 'offers', v_offers,
    'storage_paths', coalesce(to_jsonb(v_paths), '[]'::jsonb));
end $$;

revoke all on function public.delete_job_application(uuid, boolean) from public, anon;
grant execute on function public.delete_job_application(uuid, boolean) to authenticated;
