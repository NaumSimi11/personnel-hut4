-- 0071_close_jobs.sql
-- Closing job openings (plan 056). The Zoho import left the holding with
-- dozens of openings nobody works any more, each still counting its old
-- applicants as "in play". Closing a job said nothing about its candidates,
-- and nothing recorded who closed it or why.
--
-- This adds the closing stamp on the job, a trigger that keeps it honest
-- however the status is written, and one RPC that closes a selection of
-- openings and — when asked — withdraws whoever is still in play on them,
-- all-or-nothing, with the reason on every row it touches.
--
-- Order: columns → stamp trigger → close_jobs → grants.

-- --------------------------------------------------------------- columns
-- Who closed it, when, and the sentence they wrote. Null on every job that
-- is not closed — the trigger below clears all three on the way out, so a
-- stamp can never outlive the closing it describes. A job that *becomes*
-- closed is stamped; a job that arrives closed (the Zoho import, and every
-- job already closed when this migration ran) keeps whatever it was given,
-- which is usually nothing. The app names no author for those rather than
-- inventing one.
alter table public.jobs
  add column closed_at timestamptz,
  add column closed_by uuid references public.people(id),
  add column closed_reason text;

comment on column public.jobs.closed_reason is
  'Why this opening was closed. Written by close_jobs; cleared when the job reopens.';

-- ---------------------------------------------------------- stamp trigger
-- The job page closes a job with a plain update and knows nothing about
-- these columns; close_jobs sets the reason itself; an import may insert a
-- job closed from the start. So: stamp what is missing on the way into
-- `closed`, keep what is given, and clear all three on the way out. A status
-- that stays `closed` is left alone — editing a closed job must not re-date
-- its closing. Insert is covered too, or a row born closed would keep a
-- status its columns contradict for ever.
create or replace function app.jobs_closing_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'closed' then
    -- Only a job *moving* into closed is stamped, and OLD is unassigned on
    -- insert, so the operation is what tells them apart. A row inserted
    -- already closed keeps exactly the stamp it was given and no more: the
    -- Zoho import writes each job with the status it had, and dating a 2023
    -- closure today under the name of whoever ran the import would be the
    -- invention this trigger exists to avoid.
    if tg_op = 'UPDATE' and old.status is distinct from 'closed' then
      new.closed_at := coalesce(new.closed_at, now());
      new.closed_by := coalesce(new.closed_by, app.current_person_id());
    end if;
  else
    new.closed_at := null;
    new.closed_by := null;
    new.closed_reason := null;
  end if;
  return new;
end $$;

create trigger t2_closing_stamp before insert or update on public.jobs
  for each row execute function app.jobs_closing_stamp();

-- ------------------------------------------------------------- close_jobs
-- Close one opening or a selection of them. `p_withdraw` is what the app
-- calls abandoning: every application still in play on those jobs moves to
-- `withdrawn` with the same reason and a stage_change event carrying the
-- stage it really came from.
--
-- Rules, in the log_outreach (0069) shape:
--   * the same id twice is one job, one close, one count;
--   * `jobs.edit` in the job's company closes it; withdrawing its candidates
--     additionally needs `candidates.review` there — exactly what the RLS
--     policies demand of the same writes made by hand;
--   * a job already closed is counted and left alone, so re-running a
--     selection is harmless and never re-dates a closing;
--   * hired, rejected and already-withdrawn applications are never touched:
--     those are answers somebody gave, not leftovers;
--   * one refusal rolls the whole call back.
--
-- Reopening does not bring the withdrawn back. They were told. A reopened
-- job takes them again through the talent pool (0067), as a new application.
create or replace function public.close_jobs(
  p_job_ids uuid[],
  p_reason text default null,
  p_withdraw boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_withdraw boolean := coalesce(p_withdraw, false);
  v_id uuid;
  v_job record;
  v_closed int := 0;
  v_already int := 0;
  v_withdrawn int := 0;
  v_n int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if coalesce(array_length(p_job_ids, 1), 0) = 0 then
    raise exception 'Pick at least one job opening.' using errcode = '22023';
  end if;
  if length(coalesce(v_reason, '')) > 2000 then
    raise exception 'Keep the reason to 2,000 characters or fewer.' using errcode = '22023';
  end if;
  if v_withdraw and (v_reason is null or length(v_reason) < 5) then
    raise exception 'Give the reason — it is written onto every application you withdraw.'
      using errcode = '22023';
  end if;

  for v_id in select distinct u.id from unnest(p_job_ids) u(id) loop
    select j.id, j.status, j.company_id, j.title, co.name as company_name
      into v_job
      from public.jobs j
      join public.companies co on co.id = j.company_id
     where j.id = v_id;
    if not found then
      raise exception 'That job opening no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_job.company_id, 'jobs.edit') then
      raise exception 'You need "Edit job descriptions" in % to close %.',
        v_job.company_name, v_job.title using errcode = '42501';
    end if;
    if v_withdraw and not app.has_capability(v_job.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" in % to withdraw the candidates on %.',
        v_job.company_name, v_job.title using errcode = '42501';
    end if;

    if v_job.status = 'closed' then
      v_already := v_already + 1;
    else
      update public.jobs
         set status = 'closed', closed_at = now(), closed_by = v_me, closed_reason = v_reason
       where id = v_job.id;
      v_closed := v_closed + 1;
    end if;

    if v_withdraw then
      -- The event first, so it can still read the stage the row is leaving.
      insert into public.application_events
        (application_id, actor_id, kind, body, from_stage_key, to_stage_key)
        select a.id, v_me, 'stage_change', v_reason, a.stage_key, 'withdrawn'
          from public.applications a
         where a.job_id = v_job.id
           and a.stage_key not in ('hired', 'rejected', 'withdrawn');
      get diagnostics v_n = row_count;
      update public.applications
         set stage_key = 'withdrawn', withdrawn_reason = v_reason
       where job_id = v_job.id
         and stage_key not in ('hired', 'rejected', 'withdrawn');
      v_withdrawn := v_withdrawn + v_n;
    end if;
  end loop;

  return jsonb_build_object('closed', v_closed, 'already_closed', v_already, 'withdrawn', v_withdrawn);
end $$;

-- ----------------------------------------------------------------- grants
revoke all on function app.jobs_closing_stamp() from public;
revoke all on function public.close_jobs(uuid[], text, boolean) from public, anon;
grant execute on function public.close_jobs(uuid[], text, boolean) to authenticated;
