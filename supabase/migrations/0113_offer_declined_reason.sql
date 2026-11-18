-- 0113: a declined offer needs a reason, whichever way it is recorded (board card B6).
--
-- The offer card's "Candidate declined" already requires one (advance_offer,
-- 0104). The status offer_declined could also be picked by hand — Set status,
-- the Withdrawn dialog, the review save — with the note optional. Every one
-- of those goes through set_application_status, so the rule lives there.
-- The function is 0096's, unchanged but for that check.

create or replace function public.set_application_status(p_application_ids uuid[], p_sub_status_key text, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_key text := nullif(trim(coalesce(p_sub_status_key, '')), '');
  v_note text := trim(coalesce(p_note, ''));
  v_id uuid;
  v_app record;
  v_status record;
  v_job_status text;
  v_n int := 0;
  v_constraint text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if coalesce(array_length(p_application_ids, 1), 0) = 0 then
    raise exception 'Pick at least one application.' using errcode = '22023';
  end if;
  if v_key is null then
    raise exception 'Pick a status.' using errcode = '22023';
  end if;
  if length(v_note) > 2000 then
    raise exception 'Keep the note to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  select s.key, s.label, s.stage_key, s.outcome, s.archived_at into v_status
    from public.application_sub_statuses s
   where s.key = v_key;
  if not found then
    raise exception 'That status no longer exists.' using errcode = '22023';
  end if;
  if v_status.outcome = 'hired' then
    raise exception 'Hire through the offer — "Hired" is set when the offer is accepted.' using errcode = '22023';
  end if;
  -- 0113 (B6): a declined offer says why, by whichever door it is recorded —
  -- the offer card's advance_offer already insists.
  if v_key = 'offer_declined' and v_note = '' then
    raise exception 'Record why the candidate declined the offer.' using errcode = '22023';
  end if;
  if v_status.archived_at is not null then
    raise exception '"%" is retired — pick another status.', v_status.label using errcode = '22023';
  end if;

  for v_id in select distinct u.id from unnest(p_application_ids) u(id) loop
    select a.id, a.company_id, a.stage_key, a.sub_status_key, a.closed_at, a.rejected_reason, a.withdrawn_reason,
           c.full_name, co.name as company_name, os.label as old_label, os.outcome as old_outcome
      into v_app
      from public.applications a
      join public.candidates c on c.id = a.candidate_id
      join public.companies co on co.id = a.company_id
      left join public.application_sub_statuses os on os.key = a.sub_status_key
     where a.id = v_id;
    if not found then
      raise exception 'That application no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_app.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" in % to set a status.', v_app.company_name
        using errcode = '42501';
    end if;
    if v_app.closed_at is not null then
      raise exception 'This job was closed on %. Reopen the job first.', to_char(v_app.closed_at, 'YYYY-MM-DD')
        using errcode = '22023';
    end if;
    -- A row already rejected or withdrawn when its job closed never got the
    -- closure mark; it must not be reopened under a closed or filled job.
    if v_status.outcome = 'open' then
      select j.status into v_job_status from public.applications a2
        join public.jobs j on j.id = a2.job_id where a2.id = v_app.id;
      if v_job_status in ('closed', 'filled') then
        raise exception 'This job is %. Reopen the job first.', v_job_status using errcode = '22023';
      end if;
    end if;
    -- Any other status would move a hire out of Hired.
    if v_app.old_outcome = 'hired' then
      raise exception '% was hired from this application. It stays on the record.', v_app.full_name
        using errcode = '22023';
    end if;
    insert into public.application_events
      (application_id, actor_id, kind, body, from_stage_key, to_stage_key, from_sub_status_key, to_sub_status_key)
    values (v_app.id, v_me,
            case when v_app.stage_key is distinct from v_status.stage_key then 'stage_change'
                 when v_status.stage_key = 'screening' then 'outreach'
                 else 'status_change' end,
            nullif(v_note, ''), v_app.stage_key, v_status.stage_key, v_app.sub_status_key, v_key);
    begin
      update public.applications
         set stage_key = v_status.stage_key,
             sub_status_key = v_key,
             rejected_reason = case
               when v_status.outcome = 'rejected'
                and (btrim(coalesce(v_app.rejected_reason, '')) = ''
                     or lower(btrim(v_app.rejected_reason)) = lower(btrim(coalesce(v_app.old_label, ''))))
               then v_status.label else rejected_reason end,
             withdrawn_reason = case
               when v_status.outcome = 'withdrew'
                and (btrim(coalesce(v_app.withdrawn_reason, '')) = ''
                     or lower(btrim(v_app.withdrawn_reason)) = lower(btrim(coalesce(v_app.old_label, ''))))
               then v_status.label else withdrawn_reason end
       where id = v_app.id;
    exception when unique_violation then
      -- Back in play from a finished status while a newer one is open.
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'applications_one_open_per_candidate' then
        raise exception '% already has an open application for this job.', v_app.full_name using errcode = '22023';
      end if;
      raise;
    end;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('set', v_n);
end $$;
