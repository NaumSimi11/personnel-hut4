-- 0037_employment_corrections.sql
-- Correcting an employment record (asked for while setting the system up).
-- Until now every write to an employment period either added one (Add
-- employment / Rehire) or recorded a dated event (schedule_employment_change,
-- transfer_employment). Neither fixes a period that is simply wrong — the
-- Field Notebook import gave all 42 employments a start date of 2026-01-01,
-- and correcting one by adding a second period is refused by
-- no_overlapping_employment, which is the constraint doing its job.
--
-- A correction is not a change: it does not happen on a date, it says the
-- record never described reality. So it edits the period in place and keeps
-- the old picture, the new one, who and why — the shape leave_corrections
-- (0032) already set for the same problem.
--
-- Deliberately not corrected here: the end date and last working date, which
-- the departure flow owns, and the company, which transfer_employment owns.

create table public.employment_corrections (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.employment_periods(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  person_id uuid not null references public.people(id),
  old_start_date date not null,
  old_job_title text not null,
  old_employment_type_key text,
  new_start_date date not null,
  new_job_title text not null,
  new_employment_type_key text,
  reason text,
  corrected_by uuid references public.people(id),
  corrected_at timestamptz not null default now()
);
create index employment_corrections_period_idx
  on public.employment_corrections (period_id, corrected_at desc);
alter table public.employment_corrections enable row level security;
-- The facts are directory-level; the reason is not, so the audit redacts it.
create policy sel on public.employment_corrections for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'people.view'));
grant select on public.employment_corrections to authenticated;
grant all on public.employment_corrections to service_role;
create trigger audit after insert on public.employment_corrections
  for each row execute function app.audit_redacted('reason');

/**
 * Correct what an employment period says. Null job title or type means "leave
 * it as it is"; the start date is always required, because correcting it is
 * the reason this exists.
 *
 * The period keeps its id, so everything hanging off it — leave, documents,
 * equipment, payroll lines — stays attached.
 */
create or replace function public.correct_employment(
  p_period_id uuid,
  p_start_date date,
  p_job_title text default null,
  p_employment_type_key text default null,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_p record;
  v_title text;
  v_type text;
  v_status text;
begin
  select * into v_p from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'That employment no longer exists.' using errcode = 'P0002';
  end if;
  if not app.has_capability(v_p.company_id, 'employment.edit') then
    raise exception 'Correcting an employment requires employment.edit'
      using errcode = '42501';
  end if;
  if p_start_date is null then
    raise exception 'A start date is required.' using errcode = '22023';
  end if;

  v_title := coalesce(nullif(btrim(p_job_title), ''), v_p.job_title);
  -- The type is optional on a period, so only a value that is actually there
  -- is checked; null keeps whatever the period already had (which may be none).
  v_type := coalesce(nullif(btrim(p_employment_type_key), ''), v_p.employment_type_key);
  if v_type is not null and not exists (select 1 from public.employment_types where key = v_type) then
    raise exception 'Unknown employment type: %', v_type using errcode = '22023';
  end if;
  if v_p.end_date is not null and p_start_date > v_p.end_date then
    raise exception 'The start date cannot be after the end date (%).', v_p.end_date
      using errcode = '22023';
  end if;
  if v_p.last_working_date is not null and p_start_date > v_p.last_working_date then
    raise exception 'The start date cannot be after the last working date (%).', v_p.last_working_date
      using errcode = '22023';
  end if;

  -- no_overlapping_employment would refuse this anyway, with a message nobody
  -- can act on. Say which fact is in the way instead.
  if exists (
    select 1 from public.employment_periods o
    where o.person_id = v_p.person_id
      and o.id <> v_p.id
      and o.status <> 'draft'
      and daterange(o.start_date, coalesce(o.end_date, 'infinity'::date), '[]')
          && daterange(p_start_date, coalesce(v_p.end_date, 'infinity'::date), '[]')
  ) then
    raise exception 'That start date overlaps another employment this person holds.'
      using errcode = '23P01';
  end if;

  -- A correction never decides whether someone has left: it only keeps the
  -- before/after-today states honest for a period that is still running.
  v_status := case
    when v_p.status in ('active', 'pre_start')
      then case when p_start_date > current_date then 'pre_start' else 'active' end
    else v_p.status
  end;

  insert into public.employment_corrections (
    period_id, company_id, person_id,
    old_start_date, old_job_title, old_employment_type_key,
    new_start_date, new_job_title, new_employment_type_key,
    reason, corrected_by
  ) values (
    v_p.id, v_p.company_id, v_p.person_id,
    v_p.start_date, v_p.job_title, v_p.employment_type_key,
    p_start_date, v_title, v_type,
    nullif(btrim(p_reason), ''), v_me
  );

  update public.employment_periods
     set start_date = p_start_date,
         job_title = v_title,
         employment_type_key = v_type,
         status = v_status
   where id = p_period_id;

  return jsonb_build_object(
    'id', v_p.id,
    'start_date', p_start_date,
    'job_title', v_title,
    'employment_type_key', v_type,
    'status', v_status
  );
end $$;

revoke all on function public.correct_employment(uuid, date, text, text, text) from public;
grant execute on function public.correct_employment(uuid, date, text, text, text) to authenticated;
