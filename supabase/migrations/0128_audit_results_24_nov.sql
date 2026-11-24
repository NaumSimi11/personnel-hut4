-- 0128 — HR's audit results of 24 Nov (Hiring_Module_Audit_Green_Points 1.docx).
--
--  * T14 / B5: a new-hire notice is held only when nobody can receive it.
--    Fields not filled in (Hut4 has no locations, so Location never could be)
--    no longer stop it: the mail goes and lists them.
--  * B7 follow-up: Hired needs an accepted offer. Setting Offer made -> Hired
--    by hand skipped the offer, its approval and the signed contract, and
--    filled a real job on 20 Nov. Imports and the database owner are exempt.
--  * A Hired application cannot be deleted: the employee it made stayed
--    behind on 20 Nov. Did not start is the way back.
--  * B4: Did not start on the first day and the week after, not only before.
--  * C5: Indeed is not used; the channel is archived like the internal board.
--  * C3: the buddy is a colleague picked from the company's employees, who is
--    told; picking one ticks the "Buddy assigned" line.

begin;

-- ------------------------------------------------------------ T14 / B5
CREATE OR REPLACE FUNCTION app.raise_handover(p_event text, p_person_id uuid, p_company_id uuid, p_period_id uuid, p_plan_id uuid, p_occasion text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.handover_recipients;
  v_fields jsonb;
  v_missing text[];
  v_stripped text[];
  v_to text;
  v_key text;
  v_val text;
  v_label text;
  v_sens text;
  v_n int := 0;
  v_inserted int;
begin
  for r in select * from app.handover_recipients_for(p_company_id) where p_event = any(events) loop
    v_fields := '{}'::jsonb; v_missing := '{}'; v_stripped := '{}';
    foreach v_key in array r.fields loop
      select label, sensitivity into v_label, v_sens from app.handover_fields() where key = v_key;
      if v_label is null then continue; end if;
      if v_sens <> 'plain' and not r.trusted then
        v_stripped := array_append(v_stripped, v_label);
        continue;
      end if;
      v_val := app.handover_value(v_key, p_person_id, p_period_id);
      if v_val is null and v_key in ('starter_kit', 'equipment_held') then
        -- A list that is empty is an answer, not a gap (the kit itself is 049's).
        v_val := 'None';
      end if;
      if v_val is null then
        v_missing := array_append(v_missing, v_label);
      else
        v_fields := v_fields || jsonb_build_object(v_key, jsonb_build_object('label', v_label, 'value', v_val));
      end if;
    end loop;
    v_to := app.handover_address(r, p_period_id, p_company_id);
    if v_to is null then v_missing := array_prepend('Address for ' || r.label, v_missing); end if;
    insert into public.handover_sends
      (person_id, company_id, plan_id, employment_period_id, recipient_id, recipient_label, event, to_email,
       fields, stripped, missing, status, dedupe_key)
    values (p_person_id, p_company_id, p_plan_id, p_period_id, r.id, r.label, p_event, v_to,
            v_fields, v_stripped, v_missing,
            case when v_to is null then 'missing' else 'pending' end,  -- 0128: held only with nobody to send to
            'handover:' || p_event || ':' || p_person_id || ':' || r.id || ':' || p_occasion)
    on conflict (dedupe_key) do nothing;
    get diagnostics v_inserted = row_count;
    v_n := v_n + v_inserted;
  end loop;
  return v_n;
end $function$;

-- ------------------------------------------------- Hired needs an accepted offer
create or replace function app.guard_hire_needs_offer() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if current_setting('role', true) is distinct from 'authenticated' then return new; end if;
  if new.stage_key = 'hired'
     and (tg_op = 'INSERT' or old.stage_key is distinct from 'hired')
     and not exists (select 1 from public.offers o where o.application_id = new.id and o.status = 'accepted') then
    raise exception 'Hired needs an accepted offer. Record the offer and the candidate''s answer on the Offer tab first.'
      using errcode = '22023';
  end if;
  return new;
end $$;

drop trigger if exists t4_hire_needs_offer on public.applications;
create trigger t4_hire_needs_offer before insert or update of stage_key on public.applications
  for each row execute function app.guard_hire_needs_offer();

-- -------------------------------------------- a Hired application stays
create or replace function app.guard_delete_hired() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if current_setting('role', true) is distinct from 'authenticated' then return old; end if;
  if old.stage_key = 'hired' or old.employment_period_id is not null then
    raise exception 'A hired application cannot be deleted. If the hire is not going ahead, open the employee and use Did not start.'
      using errcode = '22023';
  end if;
  return old;
end $$;

drop trigger if exists t0_keep_hired on public.applications;
create trigger t0_keep_hired before delete on public.applications
  for each row execute function app.guard_delete_hired();

-- ------------------------------------------------------------------ B4
CREATE OR REPLACE FUNCTION public.mark_did_not_start(p_period_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := app.current_person_id();
  v_reason text := trim(coalesce(p_reason, ''));
  v_p public.employment_periods;
  v_app public.applications;
  v_name text;
  v_runners int := 0;
  v_to uuid;
  v_job_status text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_p from public.employment_periods where id = p_period_id for update;
  if not found then
    raise exception 'That employment no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_p.company_id, 'employment.edit') then
    raise exception 'You need "Edit employment information" in this company.' using errcode = '42501';
  end if;
  -- 0128: before the first day, on it, and for a week after (a no-show is often noticed late).
  if not (v_p.status = 'pre_start' or (v_p.status = 'active' and v_p.start_date >= current_date - 7)) then
    raise exception 'Did not start is for a hire who has not started, or started in the last 7 days.' using errcode = '22023';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Say why the hire did not start (withdrew, did not show up, offer rescinded…).' using errcode = '22023';
  end if;
  select full_name into v_name from public.people where id = v_p.person_id;

  update public.employment_periods set status = 'did_not_start', end_date = start_date where id = v_p.id;
  update public.plan_tasks set status = 'skipped'
   where status in ('open', 'blocked')
     and plan_id in (select id from public.plans where employment_period_id = v_p.id and kind = 'onboarding');
  update public.plans set status = 'cancelled'
   where employment_period_id = v_p.id and kind = 'onboarding' and status = 'in_progress';

  for v_to in
    select distinct x from (
      select h as x from app.capability_holders(v_p.company_id, 'it.view') h
      union select h from app.capability_holders(v_p.company_id, 'payroll.individual') h
    ) s where x is not null and x <> v_me
  loop
    perform app.notify(v_to, v_p.company_id, 'hire.did_not_start', 'Did not start: ' || coalesce(v_name, 'new hire'),
      v_p.job_title || ' · was to start ' || to_char(v_p.start_date, 'DD Mon YYYY') || ' · ' || v_reason,
      '/people/' || v_p.person_id, 'employment_period', v_p.id, 'hire.did_not_start:' || v_p.id, true);
  end loop;

  select * into v_app from public.applications where employment_period_id = v_p.id limit 1;
  if found then
    insert into public.application_events (application_id, actor_id, kind, body, from_stage_key, to_stage_key)
    values (v_app.id, v_me, 'status_change', 'Did not start: ' || v_reason, v_app.stage_key, v_app.stage_key);
    perform set_config('app.bulk_import', 'on', true);
    update public.applications set stage_key = 'interview', sub_status_key = 'withdrawn',
           withdrawn_reason = 'Did not start: ' || v_reason, employment_period_id = null
     where id = v_app.id;
    perform set_config('app.bulk_import', 'off', true);
    select status into v_job_status from public.jobs where id = v_app.job_id;
    if v_job_status = 'filled' then
      update public.jobs set status = 'open' where id = v_app.job_id;
    end if;
    select count(*) into v_runners from public.applications
     where job_id = v_app.job_id and in_play and id <> v_app.id;
    v_to := coalesce(v_app.owner_id, (select hiring_manager_id from public.jobs where id = v_app.job_id));
    if v_to is not null and v_to <> v_me then
      perform app.notify(v_to, v_p.company_id, 'hire.reopened', 'Position reopened: ' || v_p.job_title,
        coalesce(v_name, 'The hire') || ' did not start · ' || v_runners || ' candidate(s) still in play',
        '/hiring/jobs/' || v_app.job_id, 'job', v_app.job_id, 'hire.reopened:' || v_p.id);
    end if;
  end if;
  return jsonb_build_object('status', 'did_not_start', 'runners_up', v_runners, 'job_id', v_app.job_id);
end $function$;

-- ------------------------------------------------------------------ C5
update public.channels set archived_at = now() where key = 'indeed' and archived_at is null;

-- ------------------------------------------------------------------ C3
alter table public.plans add column if not exists buddy_id uuid references public.people(id) on delete set null;

/** Who may pick the buddy on a checklist: task assigners or completers, or whoever owns the buddy line. */
create or replace function app.may_pick_buddy(p_plan public.plans) returns boolean
language sql stable security definer set search_path = ''
as $$
  select app.has_capability(p_plan.company_id, 'tasks.assign')
      or app.has_capability(p_plan.company_id, 'tasks.complete')
      or exists (select 1 from public.plan_tasks t
                  where t.plan_id = p_plan.id and t.task_key = 'buddy' and t.owner_id = app.current_person_id())
$$;

/** The company's current employees a buddy can be picked from (not the new hire). */
create or replace function public.buddy_options(p_plan_id uuid)
returns table (id uuid, full_name text, job_title text)
language plpgsql stable security definer set search_path = ''
as $$
declare v_plan public.plans;
begin
  select * into v_plan from public.plans where plans.id = p_plan_id;
  if not found or not app.may_pick_buddy(v_plan) then
    raise exception 'You cannot pick the buddy on this checklist.' using errcode = '42501';
  end if;
  return query
    select distinct on (p.full_name, p.id) p.id, p.full_name, ep.job_title
      from public.employment_periods ep
      join public.people p on p.id = ep.person_id
     where ep.company_id = v_plan.company_id
       and ep.status = 'active'
       and p.archived_at is null
       and p.id <> v_plan.person_id
     order by p.full_name, p.id, ep.start_date desc;
end $$;

/** Pick (or change) the buddy: ticks the line and tells the buddy. */
create or replace function public.set_onboarding_buddy(p_plan_id uuid, p_buddy_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := app.current_person_id();
  v_plan public.plans;
  v_hire text;
  v_title text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_plan from public.plans where id = p_plan_id for update;
  if not found or v_plan.kind <> 'onboarding' then
    raise exception 'That onboarding checklist no longer exists.' using errcode = '22023';
  end if;
  if not app.may_pick_buddy(v_plan) then
    raise exception 'You cannot pick the buddy on this checklist.' using errcode = '42501';
  end if;
  if v_plan.status <> 'in_progress' then
    raise exception 'That checklist is closed.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.buddy_options(p_plan_id) o where o.id = p_buddy_id) then
    raise exception 'Pick a current employee of this company as the buddy.' using errcode = '22023';
  end if;

  update public.plans set buddy_id = p_buddy_id where id = p_plan_id;
  update public.plan_tasks
     set status = 'done', done_at = now(), done_by = v_me
   where plan_id = p_plan_id and task_key = 'buddy' and status in ('open', 'blocked');

  select p.full_name, coalesce(ep.job_title, '') into v_hire, v_title
    from public.people p left join public.employment_periods ep on ep.id = v_plan.employment_period_id
   where p.id = v_plan.person_id;
  if p_buddy_id <> v_me then
    perform app.notify(p_buddy_id, v_plan.company_id, 'onboarding.buddy',
      'You are the buddy for ' || coalesce(v_hire, 'a new colleague'),
      coalesce(nullif(v_title, '') || ' · ', '')
        || coalesce('starts ' || to_char(v_plan.start_date, 'DD Mon YYYY') || ' · ', '')
        || 'show them around and answer their questions in the first weeks.',
      '/people/' || v_plan.person_id, 'plan', v_plan.id,
      'onboarding.buddy:' || v_plan.id || ':' || p_buddy_id, false);
  end if;
  return jsonb_build_object('plan_id', p_plan_id, 'buddy_id', p_buddy_id);
end $$;

revoke all on function app.may_pick_buddy(public.plans) from public;
revoke all on function public.buddy_options(uuid) from public;
revoke all on function public.set_onboarding_buddy(uuid, uuid) from public;
grant execute on function app.may_pick_buddy(public.plans) to authenticated, service_role;
grant execute on function public.buddy_options(uuid) to authenticated, service_role;
grant execute on function public.set_onboarding_buddy(uuid, uuid) to authenticated, service_role;

commit;
