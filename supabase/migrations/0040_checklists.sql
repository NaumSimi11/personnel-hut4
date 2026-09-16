-- 0040_checklists.sql
-- Plan 047: checklists per person, editable per company, worked as a
-- checklist.
--   1. template_tasks.key — a stable name for the lines hooks care about
--      ('private_details', 'starter_kit', 'handover', 'welcome_note',
--      'policies', 'return_form'…), so a self-ticking rule finds its line by
--      meaning, not by title. plan_tasks carry it too.
--   2. Richer holding-wide defaults (the MK reality, the US items dropped),
--      replaced in place on the existing template rows; running checklists
--      hold copies and are untouched.
--   3. Template editing through RPCs: upsert / retire / reorder, with
--      copy-on-write — a company's first edit copies the holding default
--      into a company template, the default stays the default.
--   4. add_plan_task — the one-off line on one person's checklist.
--   5. cancel_departure — the way back from a scheduled departure.
--   6. The first self-ticking hook: "Personal, ID and bank details
--      collected" is done once both are on file.

-- ----------------------------------------------------------------- 1. keys
alter table public.template_tasks add column key text;
alter table public.template_tasks add column archived_at timestamptz;
create unique index template_tasks_key_idx on public.template_tasks (template_id, key)
  where key is not null and archived_at is null;
alter table public.plan_tasks add column task_key text;
create index plan_tasks_key_idx on public.plan_tasks (plan_id, task_key) where task_key is not null;

-- --------------------------------------------------------------- 2. defaults
-- The two holding templates keep their ids; their lines are replaced.
create or replace function app.seed_default_checklists() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_on uuid;
  v_off uuid;
begin
  select id into v_on from public.task_templates where company_id is null and kind = 'onboarding' and active order by created_at limit 1;
  select id into v_off from public.task_templates where company_id is null and kind = 'offboarding' and active order by created_at limit 1;
  if v_on is null then
    insert into public.task_templates (company_id, kind, name) values (null, 'onboarding', 'Standard onboarding') returning id into v_on;
  end if;
  if v_off is null then
    insert into public.task_templates (company_id, kind, name) values (null, 'offboarding', 'Standard offboarding') returning id into v_off;
  end if;
  -- Lines that already ran keep their plan_tasks copies (template_task_id is only a pointer).
  update public.plan_tasks set template_task_id = null where template_task_id in (select id from public.template_tasks where template_id in (v_on, v_off));
  delete from public.template_tasks where template_id in (v_on, v_off);
  insert into public.template_tasks (template_id, key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order)
  select v_on, v.* from (values
    ('agreement',        'Employment agreement signed',                  'The signed agreement is on the record under Documents.',                     'hr',       'before_start', -3, true,  true,  10),
    ('private_details',  'Personal, ID and bank details collected',      'Ticks itself once the national ID and the bank account are on the record.', 'hr',       'before_start', -3, true,  false, 20),
    ('work_account',     'Work account and email created',               null,                                                                          'it',       'before_start', -1, true,  false, 30),
    ('starter_kit',      'Starter kit issued',                           'Laptop, monitor, badge — whatever the company hands every starter.',          'it',       'before_start', -1, true,  false, 40),
    ('system_access',    'System access granted',                        null,                                                                          'it',       'before_start', -1, false, false, 50),
    ('welcome_note',     'Welcome note sent with policies',              null,                                                                          'hr',       'before_start', -2, false, false, 60),
    ('first_day',        'First-day details shared',                     'Where to come, when, who to ask for.',                                        'hr',       'before_start', -2, true,  false, 70),
    ('handover',         'Handover sent to accounting and IT',           'Who needs what about the new colleague — bank account, start date, kit.',    'hr',       'before_start', -1, false, false, 80),
    ('team_intro',       'Team introduction',                            null,                                                                          'manager',  'day_one',       0, false, false, 90),
    ('first_one_on_one', 'First 1:1 with manager',                       null,                                                                          'manager',  'week_one',      2, false, false, 100),
    ('policies',         'Policies acknowledged',                        'Ticks itself once every published policy is acknowledged.',                  'employee', 'week_one',      5, false, false, 110)
  ) as v(key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order);
  insert into public.template_tasks (template_id, key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order)
  select v_off, v.* from (values
    ('letter',           'Resignation / termination letter on file',      null,                                                                         'hr',      'before_last_day', -10, false, true,  10),
    ('handover_accepted','Handover documented and accepted',              null,                                                                         'manager', 'before_last_day',  -5, true,  false, 20),
    ('exit_conversation','Exit conversation held',                        null,                                                                         'hr',      'before_last_day',  -2, false, false, 30),
    ('return_form',      'Equipment returned and return form signed',     'Everything the person holds, back and signed for.',                          'it',      'last_day',          0, true,  false, 40),
    ('access_removed',   'Accounts and access removed',                   null,                                                                         'it',      'last_day',          0, true,  false, 50),
    ('handover_out',     'Departure sent to accounting',                  null,                                                                         'hr',      'last_day',          0, false, false, 60),
    ('final_pay',        'Final pay and documents issued',                null,                                                                         'hr',      'after_departure',   3, false, false, 70),
    ('manager_signoff',  'Manager sign-off',                              null,                                                                         'manager', 'after_departure',   1, false, false, 80)
  ) as v(key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order);
end $$;
select app.seed_default_checklists();
drop function app.seed_default_checklists();

-- Plan starters copy the key along with the rest.
create or replace function app.copy_template_tasks(p_plan_id uuid, p_template_id uuid, p_anchor date) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into public.plan_tasks
      (plan_id, template_task_id, task_key, title, description, owner_role, phase_key,
       due_date, critical, requires_evidence, sort_order)
    select p_plan_id, tt.id, tt.key, tt.title, tt.description, tt.default_owner_role,
           tt.phase_key, p_anchor + tt.due_offset_days, tt.critical,
           tt.requires_evidence, tt.sort_order
    from public.template_tasks tt
    where tt.template_id = p_template_id and tt.archived_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- The company's own template wins, else the holding default.
create or replace function app.template_for(p_company_id uuid, p_kind text) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.task_templates
    where kind = p_kind and active and (company_id = p_company_id or company_id is null)
    order by company_id nulls last, created_at
    limit 1
$$;

create or replace function app.start_onboarding_plan(
  p_person_id uuid, p_company_id uuid, p_period_id uuid, p_start_date date
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_template_id uuid;
  v_plan_id uuid;
begin
  select id into v_plan_id from public.plans
    where employment_period_id = p_period_id and kind = 'onboarding'
    limit 1;
  if v_plan_id is not null then
    return v_plan_id;
  end if;
  v_template_id := app.template_for(p_company_id, 'onboarding');
  if v_template_id is null then
    return null;
  end if;
  insert into public.plans
      (kind, person_id, company_id, employment_period_id, template_id, hr_owner_id, start_date)
    values ('onboarding', p_person_id, p_company_id, p_period_id, v_template_id,
            app.current_person_id(), p_start_date)
    returning id into v_plan_id;
  perform app.copy_template_tasks(v_plan_id, v_template_id, p_start_date);
  perform app.tick_private_details(p_person_id);
  return v_plan_id;
end $$;

create or replace function public.schedule_departure(
  p_employment_period_id uuid,
  p_end_date date,
  p_last_working_date date default null,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period record;
  v_plan_id uuid;
  v_template_id uuid;
  v_last_day date;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.employment_periods
    where id = p_employment_period_id for update;
  if not found then
    raise exception 'Employment period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'departure.start') then
    raise exception 'Scheduling a departure requires departure.start in this company.'
      using errcode = '42501';
  end if;
  if p_end_date is null then
    raise exception 'Choose an employment end date.';
  end if;
  if p_end_date < v_period.start_date then
    raise exception 'The end date cannot be before the start date.';
  end if;
  v_last_day := coalesce(p_last_working_date, p_end_date);
  if v_last_day > p_end_date then
    raise exception 'The last working date cannot be after the employment end date.';
  end if;

  select id into v_plan_id from public.plans
    where employment_period_id = p_employment_period_id
      and kind = 'offboarding' and status = 'in_progress'
    limit 1;
  if v_plan_id is not null then
    update public.employment_periods
      set end_date = p_end_date, last_working_date = v_last_day
      where id = p_employment_period_id;
    update public.plans set start_date = v_last_day where id = v_plan_id;
    perform app.add_equipment_tasks(v_plan_id);
    return jsonb_build_object('plan_id', v_plan_id, 'already_scheduled', true);
  end if;

  update public.employment_periods
    set end_date = p_end_date, last_working_date = v_last_day
    where id = p_employment_period_id;
  if p_reason is not null and length(trim(p_reason)) > 0 then
    insert into public.employment_departure_details
        (employment_period_id, reason, recorded_by)
      values (p_employment_period_id, trim(p_reason), app.current_person_id())
      on conflict (employment_period_id) do update
        set reason = excluded.reason,
            recorded_by = excluded.recorded_by,
            recorded_at = now();
  end if;

  v_template_id := app.template_for(v_period.company_id, 'offboarding');
  insert into public.plans
      (kind, person_id, company_id, employment_period_id, template_id, hr_owner_id, start_date)
    values ('offboarding', v_period.person_id, v_period.company_id,
            p_employment_period_id, v_template_id, app.current_person_id(), v_last_day)
    returning id into v_plan_id;
  if v_template_id is not null then
    perform app.copy_template_tasks(v_plan_id, v_template_id, v_last_day);
  end if;
  perform app.add_equipment_tasks(v_plan_id);
  return jsonb_build_object('plan_id', v_plan_id, 'already_scheduled', false);
end $$;

-- ------------------------------------------------------- 3. template editing
-- Who may shape a company's checklist: tasks.assign there (0006's rule);
-- the holding default is the admins'.
create or replace function app.can_edit_template(p_template_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.task_templates t
    where t.id = p_template_id
      and (app.is_admin() or (t.company_id is not null and app.has_capability(t.company_id, 'tasks.assign'))))
$$;

/**
 * The company's own template of this kind, created from the holding default
 * the first time it is asked for (copy-on-write). Lines and order are
 * copied; the default is left as it is.
 */
create or replace function public.company_template(p_company_id uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_default uuid;
  v_name text;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_kind not in ('onboarding', 'offboarding') then
    raise exception 'Unknown checklist kind: %', p_kind using errcode = '22023';
  end if;
  if not app.has_capability(p_company_id, 'tasks.assign') then
    raise exception 'Shaping a checklist needs tasks.assign in this company.' using errcode = '42501';
  end if;
  select id into v_id from public.task_templates
    where company_id = p_company_id and kind = p_kind and active
    order by created_at limit 1;
  if v_id is not null then
    return jsonb_build_object('template_id', v_id, 'created', false);
  end if;
  select id, name into v_default, v_name from public.task_templates
    where company_id is null and kind = p_kind and active
    order by created_at limit 1;
  insert into public.task_templates (company_id, kind, name)
    values (p_company_id, p_kind, coalesce(v_name, initcap(p_kind)))
    returning id into v_id;
  if v_default is not null then
    insert into public.template_tasks
        (template_id, key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order)
      select v_id, key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order
      from public.template_tasks where template_id = v_default and archived_at is null;
  end if;
  return jsonb_build_object('template_id', v_id, 'created', true);
end $$;

/**
 * Add or change one line. p: {template_id*, id?, title*, description,
 * owner_role*, phase_key*, due_offset_days*, critical, requires_evidence}.
 * A new line lands at the end. The key of an existing line never changes.
 */
create or replace function public.upsert_template_task(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_template uuid := nullif(p ->> 'template_id', '')::uuid;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_role text := coalesce(nullif(btrim(p ->> 'owner_role'), ''), 'hr');
  v_phase text := nullif(btrim(coalesce(p ->> 'phase_key', '')), '');
  v_offset int;
  v_kind text;
  v_key text;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if v_template is null or not app.can_edit_template(v_template) then
    raise exception 'Shaping this checklist needs tasks.assign in its company.' using errcode = '42501';
  end if;
  if length(v_title) < 2 then
    raise exception 'Enter what has to be done.' using errcode = '22023';
  end if;
  if v_role not in ('hr', 'it', 'manager', 'employee', 'finance') then
    raise exception 'Unknown owner: %', v_role using errcode = '22023';
  end if;
  select kind into v_kind from public.task_templates where id = v_template;
  if v_phase is null or not exists (select 1 from public.plan_phases where key = v_phase) then
    raise exception 'Choose when it is due.' using errcode = '22023';
  end if;
  -- Onboarding phases are before_start/day_one/week_one/month_one; offboarding's are the last-day ones.
  if (v_kind = 'onboarding' and v_phase not in ('before_start', 'day_one', 'week_one', 'month_one'))
     or (v_kind = 'offboarding' and v_phase not in ('before_last_day', 'last_day', 'after_departure')) then
    raise exception 'That phase does not belong to a % checklist.', v_kind using errcode = '22023';
  end if;
  begin
    v_offset := coalesce((p ->> 'due_offset_days')::int, 0);
  exception when others then
    raise exception 'Days must be a whole number.' using errcode = '22023';
  end;
  if v_offset not between -60 and 120 then
    raise exception 'Days must be between -60 and 120.' using errcode = '22023';
  end if;

  if v_id is null then
    -- A line added back under the title of a retired keyed line regains that
    -- key, so the hook that ticks it (private_details, handover…) finds it.
    select key into v_key from public.template_tasks
      where template_id = v_template and archived_at is not null and key is not null
        and lower(title) = lower(v_title)
      order by archived_at desc limit 1;
    insert into public.template_tasks
        (template_id, key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order)
      values (v_template, v_key, v_title, nullif(btrim(coalesce(p ->> 'description', '')), ''), v_role, v_phase, v_offset,
              coalesce((p ->> 'critical')::boolean, false), coalesce((p ->> 'requires_evidence')::boolean, false),
              coalesce((select max(sort_order) from public.template_tasks where template_id = v_template), 0) + 10)
      returning id into v_id;
  else
    update public.template_tasks
       set title = v_title,
           description = nullif(btrim(coalesce(p ->> 'description', '')), ''),
           default_owner_role = v_role,
           phase_key = v_phase,
           due_offset_days = v_offset,
           critical = coalesce((p ->> 'critical')::boolean, critical),
           requires_evidence = coalesce((p ->> 'requires_evidence')::boolean, requires_evidence)
     where id = v_id and template_id = v_template and archived_at is null;
    if not found then
      raise exception 'That line is no longer on the checklist.' using errcode = 'P0002';
    end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

/** A line leaves the list for new checklists; running ones keep their copy. */
create or replace function public.retire_template_task(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_template uuid;
begin
  select template_id into v_template from public.template_tasks where id = p_id and archived_at is null;
  if v_template is null then
    raise exception 'That line is no longer on the checklist.' using errcode = 'P0002';
  end if;
  if not app.can_edit_template(v_template) then
    raise exception 'Shaping this checklist needs tasks.assign in its company.' using errcode = '42501';
  end if;
  update public.template_tasks set archived_at = now() where id = p_id;
  return jsonb_build_object('id', p_id);
end $$;

/** The lines in the order given; every live line of the template must be listed once. */
create or replace function public.reorder_template_tasks(p_template_id uuid, p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_live uuid[];
begin
  if not app.can_edit_template(p_template_id) then
    raise exception 'Shaping this checklist needs tasks.assign in its company.' using errcode = '42501';
  end if;
  select coalesce(array_agg(id order by id), '{}') into v_live
    from public.template_tasks where template_id = p_template_id and archived_at is null;
  if (select array_agg(x order by x) from unnest(p_ids) x) is distinct from v_live then
    raise exception 'The order must list every line of the checklist exactly once.' using errcode = '22023';
  end if;
  update public.template_tasks t
     set sort_order = o.n * 10
    from unnest(p_ids) with ordinality as o(id, n)
   where t.id = o.id;
  return jsonb_build_object('count', cardinality(p_ids));
end $$;

revoke all on function public.company_template(uuid, text) from public, anon;
revoke all on function public.upsert_template_task(jsonb) from public, anon;
revoke all on function public.retire_template_task(uuid) from public, anon;
revoke all on function public.reorder_template_tasks(uuid, uuid[]) from public, anon;
grant execute on function public.company_template(uuid, text) to authenticated, service_role;
grant execute on function public.upsert_template_task(jsonb) to authenticated, service_role;
grant execute on function public.retire_template_task(uuid) to authenticated, service_role;
grant execute on function public.reorder_template_tasks(uuid, uuid[]) to authenticated, service_role;

-- ----------------------------------------------------------- 4. one-off task
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
  insert into public.plan_tasks (plan_id, title, owner_role, phase_key, due_date, critical, sort_order)
    values (p_plan_id, btrim(p_title), coalesce(p_owner_role, 'hr'), v_phase, p_due_date, coalesce(p_critical, false),
            coalesce((select max(sort_order) from public.plan_tasks where plan_id = p_plan_id), 0) + 10)
    returning id into v_id;
  return jsonb_build_object('id', v_id, 'phase_key', v_phase);
end $$;
revoke all on function public.add_plan_task(uuid, text, text, date, boolean) from public, anon;
grant execute on function public.add_plan_task(uuid, text, text, date, boolean) to authenticated, service_role;

-- ------------------------------------------------------- 5. cancel departure
/**
 * The way back: the dates go, the offboarding checklist is closed as
 * cancelled with the reason, the departure details stay for history.
 * Refused once the person is former (that is a rehire, not a cancel).
 */
create or replace function public.cancel_departure(p_employment_period_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period record;
  v_plan_id uuid;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.employment_periods where id = p_employment_period_id for update;
  if not found then
    raise exception 'Employment period not found.' using errcode = 'P0002';
  end if;
  if not app.has_capability(v_period.company_id, 'departure.start') then
    raise exception 'Cancelling a departure requires departure.start in this company.' using errcode = '42501';
  end if;
  if v_period.status = 'former' then
    raise exception 'This employment has already ended; rehire instead.' using errcode = '22023';
  end if;
  if v_period.end_date is null then
    raise exception 'No departure is scheduled.' using errcode = '22023';
  end if;
  if v_period.transferred_to_period_id is not null then
    raise exception 'This departure is a transfer; cancel the transfer instead.' using errcode = '22023';
  end if;
  update public.employment_periods
     set end_date = null, last_working_date = null
   where id = p_employment_period_id;
  select id into v_plan_id from public.plans
    where employment_period_id = p_employment_period_id and kind = 'offboarding' and status = 'in_progress'
    limit 1;
  if v_plan_id is not null then
    update public.plans
       set status = 'cancelled', cancelled_reason = nullif(btrim(p_reason), ''), completed_at = now()
     where id = v_plan_id;
  end if;
  return jsonb_build_object('plan_id', v_plan_id, 'status', 'employed');
end $$;
revoke all on function public.cancel_departure(uuid, text) from public, anon;
grant execute on function public.cancel_departure(uuid, text) to authenticated, service_role;

-- ------------------------------------------------------- 6. self-ticking
-- "Personal, ID and bank details collected" is done when both are on file.
create or replace function app.tick_private_details(p_person_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.person_private_details pd
             where pd.person_id = p_person_id and pd.national_id is not null
               and nullif(pd.bank_account ->> 'account_number', '') is not null) then
    update public.plan_tasks pt
       set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), pt.done_by)
      from public.plans p
     where pt.plan_id = p.id and pt.task_key = 'private_details' and pt.status in ('open', 'blocked')
       and p.person_id = p_person_id and p.kind = 'onboarding' and p.status = 'in_progress';
  end if;
end $$;

create or replace function app.private_details_tick() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.tick_private_details(new.person_id);
  return new;
end $$;
create trigger tick after insert or update on public.person_private_details
  for each row execute function app.private_details_tick();
