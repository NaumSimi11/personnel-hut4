-- 0072_tasks.sql
-- Tasks that stand on their own (plan 057).
--
-- "My tasks" has until now meant one thing only: open `plan_tasks` lines from
-- somebody's onboarding or offboarding checklist with your name on them. You
-- could not write down a thing you have to do, you could not rope a colleague
-- into one, and your manager could not hand you one. This adds the plain task
-- those three needs describe, and nothing else: a title, an optional note and
-- date, open or done.
--
-- The rules the maintainer chose (2026-09-23):
--   * a task lands on somebody else's list only from `tasks.assign` in their
--     company or from the manager named on their employment;
--   * connecting a colleague means they can work it too — they see it, they
--     are told, and either of them can tick it — while it stays the owner's
--     to change or delete;
--   * a task is seen by the people on it and nobody else. Not HR, not an
--     admin: this is a working tool, not a monitoring one.
--
-- Because of that last rule the app cannot read the names through `people`
-- (0006 shows a plain employee only themselves), so reading goes through
-- `my_tasks()`, which returns the names of the people already on the task
-- and no one else's.
--
-- Order: tables → helpers → RLS → write RPCs → read RPCs → grants.

-- ---------------------------------------------------------------- tables
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  -- Whose list it sits on. A task never changes hands: handing work over is
  -- a new task, so the old one keeps its own history.
  person_id uuid not null references public.people(id),
  -- Where it belongs, for the notification's sake. Null for somebody with no
  -- active employment — the task is still theirs.
  company_id uuid references public.companies(id),
  title text not null,
  detail text,
  due_date date,
  status text not null default 'open' check (status in ('open', 'done')),
  created_by uuid not null references public.people(id),
  done_by uuid references public.people(id),
  done_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tasks_title_length check (length(btrim(title)) between 1 and 200),
  constraint tasks_detail_length check (detail is null or length(detail) <= 2000),
  -- done and dated are one fact, so they can never drift apart
  constraint tasks_done_stamped check ((status = 'done') = (done_at is not null))
);
create index tasks_person_open_idx on public.tasks (person_id) where status = 'open';
create index tasks_created_by_idx on public.tasks (created_by);
create trigger touch before update on public.tasks
  for each row execute function app.touch_updated_at();

-- Who else is on it. Membership is the whole row: being here means you see
-- it, you were told about it, and you may tick it.
create table public.task_people (
  task_id uuid not null references public.tasks(id) on delete cascade,
  person_id uuid not null references public.people(id),
  added_by uuid references public.people(id),
  added_at timestamptz not null default now(),
  primary key (task_id, person_id)
);
create index task_people_person_idx on public.task_people (person_id);

-- --------------------------------------------------------------- helpers
-- The company a person's work belongs to: their current employment. Used for
-- the capability check and to route the notification.
create or replace function app.task_company(p_person uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select ep.company_id
    from public.employment_periods ep
   where ep.person_id = p_person and ep.status = 'active'
   order by ep.start_date desc
   limit 1
$$;

-- May I put a task on this person's list? Mine always; anyone else's only
-- with `tasks.assign` where they work, or as the manager on their employment.
create or replace function app.may_assign_task(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_self(p_person)
      or exists (
        select 1 from public.employment_periods ep
         where ep.person_id = p_person and ep.status = 'active'
           and (app.has_capability(ep.company_id, 'tasks.assign')
                or ep.manager_id = app.current_person_id()))
$$;

-- May I connect this person to a task? Anyone I can already see, plus anyone
-- employed where I am employed — colleagues, whom a plain employee cannot
-- "view" under 0006 but obviously works beside. Only their name ever leaves
-- this door, and only onto a task they are on.
create or replace function app.may_connect_task(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.is_self(p_person)
     and exists (select 1 from public.people pp where pp.id = p_person and pp.archived_at is null)
     and (
       app.can_view_person(p_person)
       or exists (
         select 1
           from public.employment_periods mine
           join public.employment_periods theirs on theirs.company_id = mine.company_id
          where mine.person_id = app.current_person_id() and mine.status = 'active'
            and theirs.person_id = p_person and theirs.status = 'active'))
$$;

-- On the task: it is mine, I set it, or I am connected to it.
create or replace function app.on_task(p_task uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
      select 1 from public.tasks t
       where t.id = p_task
         and (t.person_id = app.current_person_id() or t.created_by = app.current_person_id()))
    or exists (
      select 1 from public.task_people tp
       where tp.task_id = p_task and tp.person_id = app.current_person_id())
$$;

-- Changing the words, the date or the company it is connected to is for the
-- owner and whoever set it. A connected colleague may work it, not rewrite it.
create or replace function app.may_edit_task(p_task uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.tasks t
     where t.id = p_task
       and (t.person_id = app.current_person_id() or t.created_by = app.current_person_id()))
$$;

-- ------------------------------------------------------------------- RLS
-- Reading is the people on it. There is no client write policy at all: every
-- change goes through the functions below, which hold the rules in one place.
alter table public.tasks enable row level security;
create policy sel on public.tasks for select to authenticated using (app.on_task(id));

alter table public.task_people enable row level security;
create policy sel on public.task_people for select to authenticated using (app.on_task(task_id));

-- ------------------------------------------------------------ save_task
-- One door for "write it down", "change it" and "rope somebody in".
--   p = {id?, person_id?, title, detail?, due_date?, with_ids?[]}
-- `with_ids` replaces the connected list when present and is left alone when
-- absent, so editing a title never quietly drops a colleague.
create or replace function public.save_task(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_title text := nullif(btrim(coalesce(p->>'title', '')), '');
  v_detail text := nullif(btrim(coalesce(p->>'detail', '')), '');
  v_due date := nullif(p->>'due_date', '')::date;
  v_person uuid;
  v_task public.tasks;
  v_with uuid[] := coalesce(
    (select array_agg(distinct x::uuid) from jsonb_array_elements_text(coalesce(p->'with_ids', '[]'::jsonb)) x),
    '{}'::uuid[]);
  v_pid uuid;
  v_added uuid[] := '{}'::uuid[];
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if v_title is null then
    raise exception 'Give the task a title.' using errcode = '22023';
  end if;
  if length(v_title) > 200 then
    raise exception 'Keep the title to 200 characters or fewer.' using errcode = '22023';
  end if;
  if v_detail is not null and length(v_detail) > 2000 then
    raise exception 'Keep the note to 2,000 characters or fewer.' using errcode = '22023';
  end if;

  if v_id is null then
    v_person := coalesce(nullif(p->>'person_id', '')::uuid, v_me);
    if not app.may_assign_task(v_person) then
      raise exception 'You cannot put a task on %''s list.', coalesce(app.person_name(v_person), 'that person')
        using errcode = '42501';
    end if;
    insert into public.tasks (person_id, company_id, title, detail, due_date, created_by)
      values (v_person, app.task_company(v_person), v_title, v_detail, v_due, v_me)
      returning * into v_task;
  else
    select * into v_task from public.tasks where id = v_id;
    if not found then
      raise exception 'That task no longer exists.' using errcode = '22023';
    end if;
    if not app.may_edit_task(v_id) then
      raise exception 'Only the person whose task it is, or whoever set it, can change it.'
        using errcode = '42501';
    end if;
    if p ? 'person_id' and nullif(p->>'person_id', '')::uuid is distinct from v_task.person_id then
      raise exception 'A task does not change hands. Set a new one instead.' using errcode = '22023';
    end if;
    update public.tasks set title = v_title, detail = v_detail, due_date = v_due
     where id = v_id returning * into v_task;
  end if;

  if p ? 'with_ids' then
    if v_task.person_id = any(v_with) then
      raise exception 'That task is already theirs — they do not need connecting to it.' using errcode = '22023';
    end if;
    -- Only the arrivals are told; somebody already on it is not told twice.
    select coalesce(array_agg(x), '{}'::uuid[]) into v_added
      from unnest(v_with) x
     where not exists (select 1 from public.task_people tp where tp.task_id = v_task.id and tp.person_id = x);
    -- ...and only the arrivals are checked. Whoever is already on the task
    -- was allowed there when they were added; re-asking would mean an owner
    -- could no longer save a title once somebody else put a colleague of
    -- theirs on it. Taking somebody off needs no permission at all.
    foreach v_pid in array v_added loop
      if not app.may_connect_task(v_pid) then
        raise exception 'You cannot connect % to a task.', coalesce(app.person_name(v_pid), 'that person')
          using errcode = '42501';
      end if;
    end loop;
    delete from public.task_people tp
     where tp.task_id = v_task.id and not (tp.person_id = any(v_with));
    insert into public.task_people (task_id, person_id, added_by)
      select v_task.id, x, v_me from unnest(v_added) x;
  end if;

  -- Told once, when it lands: a task somebody else put on your list, and a
  -- task you have just been connected to.
  if v_id is null and v_task.person_id <> v_me then
    perform app.notify(v_task.person_id, v_task.company_id, 'task.assigned',
      app.person_name(v_me) || ' gave you a task: ' || v_task.title,
      coalesce(v_task.detail, '') || coalesce(' · due ' || to_char(v_task.due_date, 'DD Mon YYYY'), ''),
      '/me', 'task', v_task.id, 'task.assigned:' || v_task.id);
  end if;
  foreach v_pid in array v_added loop
    perform app.notify(v_pid, v_task.company_id, 'task.connected',
      app.person_name(v_me) || ' put you on a task: ' || v_task.title,
      'It is ' || app.person_name(v_task.person_id) || '''s task — you can work it and tick it off.',
      '/me', 'task', v_task.id, 'task.connected:' || v_task.id || ':' || v_pid);
  end loop;

  return jsonb_build_object('id', v_task.id, 'connected', coalesce(array_length(v_with, 1), 0),
                            'told', coalesce(array_length(v_added, 1), 0));
end $$;

-- -------------------------------------------------------- set_task_done
-- Anybody on the task may tick it, and untick it. The owner is told when
-- somebody else finished it — otherwise it would simply vanish from a list.
create or replace function public.set_task_done(p_task_id uuid, p_done boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_task public.tasks;
  v_done boolean := coalesce(p_done, true);
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_task from public.tasks where id = p_task_id;
  if not found or not app.on_task(p_task_id) then
    raise exception 'That task no longer exists.' using errcode = '22023';
  end if;

  update public.tasks
     set status = case when v_done then 'done' else 'open' end,
         done_at = case when v_done then now() end,
         done_by = case when v_done then v_me end
   where id = p_task_id
   returning * into v_task;

  if v_done and v_task.person_id <> v_me then
    perform app.notify(v_task.person_id, v_task.company_id, 'task.done',
      app.person_name(v_me) || ' ticked off: ' || v_task.title, null,
      '/me', 'task', v_task.id, 'task.done:' || v_task.id || ':' || v_task.done_at);
  end if;
  return jsonb_build_object('id', v_task.id, 'status', v_task.status);
end $$;

-- ---------------------------------------------------------- delete_task
create or replace function public.delete_task(p_task_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me uuid := app.current_person_id();
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.tasks where id = p_task_id) then
    raise exception 'That task no longer exists.' using errcode = '22023';
  end if;
  if not app.may_edit_task(p_task_id) then
    raise exception 'Only the person whose task it is, or whoever set it, can delete it.'
      using errcode = '42501';
  end if;
  delete from public.tasks where id = p_task_id;
  return jsonb_build_object('deleted', true);
end $$;

-- -------------------------------------------------------------- my_tasks
-- Everything I have to do, and everything I have handed out, with the names
-- of the people already on each task. The names come from here rather than
-- from `people` because a plain employee may read only their own row there,
-- and a task nobody can read the names on is useless.
create or replace function public.my_tasks() returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select app.current_person_id() as id),
  visible as (
    select t.*
      from public.tasks t, me
     where t.person_id = me.id
        or exists (select 1 from public.task_people tp where tp.task_id = t.id and tp.person_id = me.id)
  ),
  set_by_me as (
    select t.* from public.tasks t, me
     where t.created_by = me.id and t.person_id <> me.id
  ),
  shaped as (
    select t.id, t.person_id, t.company_id, t.title, t.detail, t.due_date, t.status,
           t.created_by, t.done_at, t.created_at,
           app.person_name(t.person_id) as person_name,
           app.person_name(t.created_by) as created_by_name,
           -- person_name answers 'Someone' for a null, which would put a
           -- ghost on every open task; an unticked task has no finisher.
           case when t.done_by is null then null else app.person_name(t.done_by) end as done_by_name,
           coalesce((select jsonb_agg(jsonb_build_object('id', tp.person_id, 'full_name', app.person_name(tp.person_id))
                                      order by app.person_name(tp.person_id))
                       from public.task_people tp where tp.task_id = t.id), '[]'::jsonb) as with_people,
           t.person_id = (select id from me) as is_mine
      from visible t
  ),
  shaped_out as (
    select t.id, t.person_id, t.title, t.detail, t.due_date, t.status, t.done_at, t.created_at,
           app.person_name(t.person_id) as person_name
      from set_by_me t
  )
  select jsonb_build_object(
    'mine', coalesce((select jsonb_agg(to_jsonb(s) order by s.status, s.due_date nulls last, s.created_at) from shaped s), '[]'::jsonb),
    'set_by_me', coalesce((select jsonb_agg(to_jsonb(o) order by o.status, o.due_date nulls last, o.created_at) from shaped_out o), '[]'::jsonb)
  )
$$;

-- ------------------------------------------------------- task_candidates
-- Who the dialog may offer: people I may hand a task to, and colleagues I may
-- connect. Both lists are names only, and both are exactly what the write
-- functions will accept — the dialog never offers what the door would refuse.
create or replace function public.task_candidates() returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select app.current_person_id() as id),
  everybody as (
    select distinct pp.id, pp.full_name
      from public.people pp
      join public.employment_periods ep on ep.person_id = pp.id and ep.status = 'active'
     where pp.archived_at is null
  )
  select jsonb_build_object(
    'assignable', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'full_name', e.full_name) order by e.full_name)
                              from everybody e where app.may_assign_task(e.id)), '[]'::jsonb),
    'connectable', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'full_name', e.full_name) order by e.full_name)
                               from everybody e where app.may_connect_task(e.id)), '[]'::jsonb)
  )
$$;

-- ---------------------------------------------------------------- grants
-- Select only: every write goes through the functions below, so there is
-- nothing to grant for insert, update or delete.
grant select on public.tasks, public.task_people to authenticated;
grant all on public.tasks, public.task_people to service_role;

-- `app.on_task` is what the row policies ask, so it stays executable by the
-- role the policies run as. The rest are called only from the security
-- definer functions below and are closed.
revoke all on function
  app.task_company(uuid), app.may_assign_task(uuid), app.may_connect_task(uuid),
  app.may_edit_task(uuid)
from public;
revoke all on function
  public.save_task(jsonb), public.set_task_done(uuid, boolean),
  public.delete_task(uuid), public.my_tasks(), public.task_candidates()
from public, anon;
grant execute on function
  public.save_task(jsonb), public.set_task_done(uuid, boolean),
  public.delete_task(uuid), public.my_tasks(), public.task_candidates()
to authenticated;
