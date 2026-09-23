-- 0079_manager_plan_access.sql
-- Seven corrections to 0077, from review. 0077 is already on live, so they
-- arrive as their own migration.
--
-- The important one first. 0077's backfill gave 22 live checklist lines an
-- owner, and in doing so woke a branch of the `plan_tasks` write policy that
-- had never been reachable while `owner_id` was always null:
-- `app.is_self(owner_id)` grants ALL — so an employee with no capability
-- anywhere could delete their own checklist line, mark a line that requires
-- evidence as done without any, or move the row to somebody else's plan,
-- since the WITH CHECK only ever looked at `owner_id`.
--
-- That branch was harmless as long as nobody owned anything. Filling the
-- owners is what made it dangerous, so filling the owners is what has to pay
-- for it: the branch goes, and ticking your own line becomes one function
-- that does exactly that and nothing else.
--
-- The rest is reach. A manager could open a plan (0077) but `plan_tasks` was
-- not widened with it, so they saw only their own lines — and the page
-- computes "everything critical is done" from what it can see, which would
-- have let somebody finish an onboarding with the IT lines still open. An IT
-- owner got lines pointing at plans they could not open at all. And two more
-- writers of `plan_tasks` never learned to set an owner.

-- ---------------------------------------------------------------- lookups
-- Whether the caller owns any line in this plan. SECURITY DEFINER, like
-- `manages_employment`: a policy's subquery runs as the querying role, and
-- this is asked BY the policy on `plans`, so reading `plan_tasks` here must
-- not be subject to the policy on `plan_tasks` — which itself reads `plans`.
-- Definer breaks that circle.
create or replace function app.owns_plan_line(p_plan uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.plan_tasks pt
                  where pt.plan_id = p_plan and pt.owner_id = app.current_person_id())
$$;

-- ------------------------------------------------------------------ plans
-- ...and so the IT owner, the manager, and anybody handed a single line can
-- open the page their line lives on.
drop policy sel on public.plans;
create policy sel on public.plans for select to authenticated
  using (
    app.is_self(person_id)
    or app.has_capability(company_id, 'tasks.view')
    or app.manages_employment(employment_period_id)
    or app.owns_plan_line(id)
  );

-- ------------------------------------------------------------- plan_tasks
-- Reading: whoever may read the plan may read ALL of its lines. A checklist
-- read in part is worse than one not read at all — the page decides whether
-- the critical work is finished by counting what it was given.
drop policy sel on public.plan_tasks;
create policy sel on public.plan_tasks for select to authenticated
  using (exists (
    select 1 from public.plans p where p.id = plan_id
      and (app.is_self(p.person_id)
           or app.has_capability(p.company_id, 'tasks.view')
           or app.manages_employment(p.employment_period_id)
           or app.owns_plan_line(p.id))));

-- Writing: the capabilities, and nothing else. Owning a line is not a licence
-- to rewrite it; ticking it is `complete_my_plan_task` below.
drop policy write on public.plan_tasks;
create policy write on public.plan_tasks for all to authenticated
  using (exists (
    select 1 from public.plans p where p.id = plan_id
      and (app.has_capability(p.company_id, 'tasks.assign')
           or app.has_capability(p.company_id, 'tasks.complete'))))
  with check (exists (
    select 1 from public.plans p where p.id = plan_id
      and (app.has_capability(p.company_id, 'tasks.assign')
           or app.has_capability(p.company_id, 'tasks.complete'))));

-- -------------------------------------------------- complete_my_plan_task
-- Tick the line that is yours, or untick it. The only thing an owner may do
-- to their own line, and it touches three columns.
create or replace function public.complete_my_plan_task(p_task_id uuid, p_done boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_task record;
  v_done boolean := coalesce(p_done, true);
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select pt.*, p.company_id, p.status as plan_status into v_task
    from public.plan_tasks pt join public.plans p on p.id = pt.plan_id
   where pt.id = p_task_id;
  if not found then
    raise exception 'That task no longer exists.' using errcode = '22023';
  end if;
  if not (v_task.owner_id = v_me or app.has_capability(v_task.company_id, 'tasks.complete')) then
    raise exception 'That task is not yours.' using errcode = '42501';
  end if;
  if v_task.plan_status <> 'in_progress' then
    raise exception 'That checklist is closed.' using errcode = '22023';
  end if;
  -- The line says a document has to be filed against it. Ticking it without
  -- one is the checklist agreeing that something happened when it did not.
  if v_done and v_task.requires_evidence and v_task.evidence_document_id is null then
    raise exception 'This one needs its document filed first.' using errcode = '22023';
  end if;
  if v_done and v_task.status = 'blocked' then
    raise exception 'This one is blocked. Whoever blocked it has to clear it.' using errcode = '22023';
  end if;

  update public.plan_tasks
     set status = case when v_done then 'done' else 'open' end,
         done_at = case when v_done then now() end,
         done_by = case when v_done then v_me end
   where id = p_task_id;
  return jsonb_build_object('id', p_task_id, 'status', case when v_done then 'done' else 'open' end);
end $$;

revoke all on function public.complete_my_plan_task(uuid, boolean) from public, anon;
grant execute on function public.complete_my_plan_task(uuid, boolean) to authenticated;
-- `app.owns_plan_line` and `app.manages_employment` are asked BY the policies,
-- so they stay executable by the role the policies run as. (Revoking a policy
-- helper has now broken this database three times in one day: 0072's on_task,
-- 0075's can_view_access, and this. If a function appears in a `using` clause,
-- it is not an internal.)

-- ------------------------------------------------------- the other writers
-- `copy_template_tasks` learned to set an owner in 0077; these two did not,
-- so every future departure would have re-created unowned critical lines —
-- the exact symptom 0077 set out to remove.
-- 0040's body, unchanged but for `owner_id` in the insert: same signature,
-- same phase arithmetic, same refusals.
create or replace function public.add_plan_task(
  p_plan_id uuid, p_title text, p_owner_role text default 'hr',
  p_due_date date default null, p_critical boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_plan record;
  v_phase text;
  v_id uuid;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_plan from public.plans where id = p_plan_id;
  if not found then
    raise exception 'Checklist not found.' using errcode = 'P0002';
  end if;
  if not app.has_capability(v_plan.company_id, 'tasks.assign') then
    raise exception 'Adding a task needs tasks.assign in this company.' using errcode = '42501';
  end if;
  if v_plan.status <> 'in_progress' then
    raise exception 'This checklist is closed.' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_title, ''))) < 2 then
    raise exception 'Enter what has to be done.' using errcode = '22023';
  end if;
  if coalesce(p_owner_role, 'hr') not in ('hr', 'it', 'manager', 'employee', 'finance') then
    raise exception 'Unknown owner: %', p_owner_role using errcode = '22023';
  end if;
  -- The phase follows the due date relative to the anchor (start or last day).
  v_phase := case
    when v_plan.kind = 'onboarding' then
      case when p_due_date is null or p_due_date < v_plan.start_date then 'before_start'
           when p_due_date = v_plan.start_date then 'day_one'
           when p_due_date <= v_plan.start_date + 7 then 'week_one'
           else 'month_one' end
    else
      case when p_due_date is null or p_due_date < v_plan.start_date then 'before_last_day'
           when p_due_date = v_plan.start_date then 'last_day'
           else 'after_departure' end
  end;
  insert into public.plan_tasks (plan_id, title, owner_role, owner_id, phase_key, due_date, critical, sort_order)
    values (p_plan_id, btrim(p_title), coalesce(p_owner_role, 'hr'),
            app.owner_for_role(p_plan_id, coalesce(p_owner_role, 'hr')),
            v_phase, p_due_date, coalesce(p_critical, false),
            coalesce((select max(sort_order) from public.plan_tasks where plan_id = p_plan_id), 0) + 10)
    returning id into v_id;
  return jsonb_build_object('id', v_id, 'phase_key', v_phase);
end $$;

create or replace function app.add_equipment_tasks(p_plan_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_plan record;
  v_n int;
begin
  select * into v_plan from public.plans where id = p_plan_id;
  if not found or v_plan.kind <> 'offboarding' then return 0; end if;
  insert into public.plan_tasks
      (plan_id, asset_id, title, description, owner_role, owner_id, phase_key, due_date, critical, sort_order)
    select v_plan.id, a.id,
           format('Return %s · %s%s', a.asset_tag, t.label, coalesce(' ' || a.model, '')),
           'Equipment the person still holds; take it back and record its condition on the Equipment page.',
           'it', app.owner_for_role(v_plan.id, 'it'), 'last_day', v_plan.start_date, true,
           900 + row_number() over (order by a.asset_tag)
    from public.asset_assignments aa
    join public.assets a on a.id = aa.asset_id
    join public.asset_types t on t.key = a.type_key
    where aa.person_id = v_plan.person_id and aa.returned_at is null
      and not exists (select 1 from public.plan_tasks pt where pt.plan_id = v_plan.id and pt.asset_id = a.id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;
