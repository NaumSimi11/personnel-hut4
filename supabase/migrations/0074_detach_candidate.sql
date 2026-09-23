-- 0074_detach_candidate.sql
-- Undoing an attachment (plan 060).
--
-- task.md: "we need to be able to add an existing cancidate to another
-- possiotion ( transver possition to opening or not openings )" — and, asked
-- what that needs: "yes but we need to be able to view them too, and to
-- revert them".
--
-- Attaching a candidate to the wrong job is a two-click mistake with no way
-- back. Withdrawing is not the way back: withdrawn means the person stepped
-- away, and it leaves a row on their record and in the job's history saying
-- something happened that never did. What is wanted is an undo.
--
-- So an attachment may be undone only while it is still nothing but an
-- attachment. That rule is spelled out here rather than left to the foreign
-- keys, because the keys would not save anybody: application_events,
-- application_files, interviews and scorecards all CASCADE, so a careless
-- delete would take a panel's interview feedback with it and only an offer
-- would raise a word of protest.
--
-- Once anything at all has happened, the row is history and stays: reject it,
-- or withdraw it, and the trail keeps the truth.
create or replace function public.detach_candidate_from_job(p_application_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_app record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  select a.id, a.company_id, a.stage_key, a.employment_period_id, a.source_provider,
         a.owner_id, a.next_action,
         c.full_name as candidate_name, j.title as job_title, co.name as company_name
    into v_app
    from public.applications a
    join public.candidates c on c.id = a.candidate_id
    join public.jobs j on j.id = a.job_id
    join public.companies co on co.id = a.company_id
   where a.id = p_application_id;
  if not found then
    raise exception 'That application no longer exists.' using errcode = '22023';
  end if;

  if not app.has_capability(v_app.company_id, 'candidates.review') then
    raise exception 'Undoing this needs "Record interview feedback" in %.', v_app.company_name
      using errcode = '42501';
  end if;

  -- An import is not a mistake somebody made here, and re-running it would
  -- put the row straight back.
  if v_app.source_provider is not null then
    raise exception '% came from %, so it is history rather than a mistake. Reject or withdraw it instead.',
      v_app.candidate_name, v_app.source_provider using errcode = '22023';
  end if;
  if v_app.employment_period_id is not null then
    raise exception '% was hired from this application. It stays on the record.', v_app.candidate_name
      using errcode = '22023';
  end if;
  -- An owner was told about this by email (0034's t9_notify) and is carrying
  -- it in their queue. Deleting it under them leaves a notification pointing
  -- at nothing, and no application_events row is written when somebody is
  -- assigned, so nothing else here would have caught it.
  if v_app.owner_id is not null or v_app.next_action is not null then
    raise exception '% is assigned to somebody here. Take the owner off it first, or reject or withdraw it.',
      v_app.candidate_name using errcode = '22023';
  end if;
  if v_app.stage_key <> 'new' then
    raise exception '% has already moved on from New, so this is history now. Reject or withdraw it instead.',
      v_app.candidate_name using errcode = '22023';
  end if;
  if exists (select 1 from public.application_events e where e.application_id = v_app.id) then
    raise exception 'Something has already been recorded against % here. Reject or withdraw it instead.',
      v_app.candidate_name using errcode = '22023';
  end if;
  if exists (select 1 from public.interviews i where i.application_id = v_app.id) then
    raise exception '% has an interview on this job. Reject or withdraw it instead.', v_app.candidate_name
      using errcode = '22023';
  end if;
  if exists (select 1 from public.offers o where o.application_id = v_app.id) then
    raise exception '% has an offer on this job. Reject or withdraw it instead.', v_app.candidate_name
      using errcode = '22023';
  end if;
  if exists (select 1 from public.application_files f where f.application_id = v_app.id) then
    raise exception 'A file was filed against % here. Reject or withdraw it instead, so the file keeps its place.',
      v_app.candidate_name using errcode = '22023';
  end if;

  -- The audit trigger on applications (0005) records the removal with the row
  -- it removed, so an undo is never invisible.
  delete from public.applications where id = v_app.id;

  return jsonb_build_object('detached', true, 'candidate', v_app.candidate_name, 'job', v_app.job_title);
end $$;

revoke all on function public.detach_candidate_from_job(uuid) from public, anon;
grant execute on function public.detach_candidate_from_job(uuid) to authenticated;
