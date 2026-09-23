-- 0075_person_access.sql
-- Who has access to what (plan 061).
--
-- task.md: "onobading, we need to add access to the actual worek. - the
-- manager mange that access, and on the offboarding we need to have preview
-- what we need to shut down."
--
-- Both checklists have carried a line about this since 0040 — `system_access`
-- ("System access granted") on the way in, `access_removed` ("Accounts and
-- access removed") on the way out — and both were a single tick with nothing
-- behind them. Nobody could answer "what does this person actually have?",
-- which is the question that matters on the last day: somebody leaves, and
-- whatever nobody remembered stays open.
--
-- So this is the memory, and nothing more. No provisioning, no integration,
-- no credentials: a list of systems, and a row per person saying they were
-- given one and when it was taken away. `account` holds a username or a
-- mailbox — never a password, and nothing that unlocks anything on its own.
--
-- Order: catalogue → records → helpers → RLS → RPCs → the two ticks → grants.

-- ------------------------------------------------------------- catalogue
-- One holding-wide list. Companies share their tooling here, and a per-company
-- list would mean maintaining five of them to say "Google Workspace" five
-- times. Retirement is `archived_at`, so history keeps its name.
create table public.access_systems (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  label text not null check (length(btrim(label)) between 1 and 80),
  -- Where to go to grant or remove it, in a sentence. This is the part that
  -- saves the next person half an hour.
  note text,
  sort_order int not null default 0,
  archived_at timestamptz
);

-- A starting list, deliberately generic: every one of these is expected to be
-- renamed or retired once somebody looks at it, the way the hiring labels are.
insert into public.access_systems (key, label, note, sort_order) values
  ('email',          'Email and calendar',   'The work mailbox and the shared calendars.',          10),
  ('file_storage',   'File storage',         'Shared drives and folders.',                          20),
  ('chat',           'Chat',                 'The team messenger.',                                 30),
  ('vpn',            'VPN and network',      'Remote access to the internal network.',              40),
  ('building',       'Building access',      'Door cards and keys — say which door in the note.',   50),
  ('code',           'Code repositories',    'Source control and anything that deploys from it.',   60),
  ('finance_tools',  'Finance systems',      'Accounting, invoicing, banking portals.',             70),
  ('hr_tools',       'HR systems',           'This app, and anything holding employee records.',    80);

alter table public.access_systems enable row level security;
create policy read_all on public.access_systems for select to authenticated using (true);
create policy admin_write on public.access_systems for all to authenticated
  using (app.is_admin()) with check (app.is_admin());
grant select on public.access_systems to authenticated;
grant all on public.access_systems to service_role;

-- --------------------------------------------------------------- records
create table public.person_access (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id),
  company_id uuid not null references public.companies(id),
  system_key text not null references public.access_systems(key),
  -- The username, mailbox or card number. NEVER a secret: nothing here should
  -- open anything on its own.
  account text check (account is null or length(account) <= 200),
  status text not null default 'granted' check (status in ('granted', 'revoked')),
  note text check (note is null or length(note) <= 1000),
  granted_at timestamptz not null default now(),
  granted_by uuid references public.people(id),
  revoked_at timestamptz,
  revoked_by uuid references public.people(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Revoked and dated are one fact (the 0071 lesson).
  constraint person_access_revoked_stamped check ((status = 'revoked') = (revoked_at is not null))
);
-- One live grant per person, company and system; the revoked rows stay as
-- history, so "had it, lost it, got it again" reads correctly.
create unique index person_access_one_live
  on public.person_access (person_id, company_id, system_key) where status = 'granted';
create index person_access_person_idx on public.person_access (person_id, status);
create trigger touch before update on public.person_access
  for each row execute function app.touch_updated_at();
create trigger audit after insert or update or delete on public.person_access
  for each row execute function app.audit();

-- --------------------------------------------------------------- helpers
-- Seeing the list: the person themselves, IT and HR where they work, the
-- manager named on their employment, and admins. Knowing what you have is not
-- privileged; it is the list nobody could produce that caused the problem.
create or replace function app.can_view_access(p_person uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_self(p_person)
      or app.is_admin()
      or app.has_capability(p_company, 'it.view')
      or app.has_capability(p_company, 'tasks.view')
      or exists (select 1 from public.employment_periods ep
                  where ep.person_id = p_person and ep.company_id = p_company
                    and ep.status = 'active' and ep.manager_id = app.current_person_id())
$$;

-- Granting and taking away: IT, the manager, admins. The maintainer's rule —
-- "the manager manage that access" — and not the person themselves, who would
-- otherwise be able to write down that they gave themselves the finance system.
create or replace function app.can_manage_access(p_person uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin()
      or app.has_capability(p_company, 'it.assign')
      or exists (select 1 from public.employment_periods ep
                  where ep.person_id = p_person and ep.company_id = p_company
                    and ep.status = 'active' and ep.manager_id = app.current_person_id())
$$;

-- ------------------------------------------------------------------- RLS
alter table public.person_access enable row level security;
create policy sel on public.person_access for select to authenticated
  using (app.can_view_access(person_id, company_id));
grant select on public.person_access to authenticated;
grant all on public.person_access to service_role;

-- ------------------------------------------------------------------ RPCs
-- Writing it down. p = {person_id, company_id, system_key, account?, note?}
create or replace function public.grant_access(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_person uuid := nullif(p->>'person_id', '')::uuid;
  v_company uuid := nullif(p->>'company_id', '')::uuid;
  v_system text := nullif(btrim(coalesce(p->>'system_key', '')), '');
  v_account text := nullif(btrim(coalesce(p->>'account', '')), '');
  v_note text := nullif(btrim(coalesce(p->>'note', '')), '');
  v_label text;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if v_person is null or v_company is null then
    raise exception 'Say who, and where.' using errcode = '22023';
  end if;
  select label into v_label from public.access_systems
   where key = v_system and archived_at is null;
  if v_label is null then
    raise exception 'Pick a system from the list.' using errcode = '22023';
  end if;
  if not app.can_manage_access(v_person, v_company) then
    raise exception 'Recording access needs "Assign requests" where this person works, or being their manager.'
      using errcode = '42501';
  end if;
  if length(coalesce(v_account, '')) > 200 then
    raise exception 'Keep the account to 200 characters or fewer.' using errcode = '22023';
  end if;

  insert into public.person_access (person_id, company_id, system_key, account, note, granted_by)
    values (v_person, v_company, v_system, v_account, v_note, v_me)
    returning id into v_id;
  perform app.tick_system_access(v_person);
  return jsonb_build_object('id', v_id, 'system', v_label);
exception when unique_violation then
  raise exception '% is already recorded for this person.', v_label using errcode = '22023';
end $$;

-- Taking it away. The row stays: the last day's question is "what did they
-- have", and an answer that deletes itself is no answer.
create or replace function public.revoke_access(p_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_row record;
  v_label text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select pa.*, s.label into v_row
    from public.person_access pa join public.access_systems s on s.key = pa.system_key
   where pa.id = p_id;
  if not found then
    raise exception 'That access record no longer exists.' using errcode = '22023';
  end if;
  if not app.can_manage_access(v_row.person_id, v_row.company_id) then
    raise exception 'Removing access needs "Assign requests" where this person works, or being their manager.'
      using errcode = '42501';
  end if;
  if v_row.status = 'revoked' then
    return jsonb_build_object('id', v_row.id, 'system', v_row.label, 'already', true);
  end if;

  update public.person_access
     set status = 'revoked', revoked_at = now(), revoked_by = v_me,
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note)
   where id = p_id;
  perform app.tick_access_removed(v_row.person_id);
  return jsonb_build_object('id', v_row.id, 'system', v_row.label, 'already', false);
end $$;

-- ------------------------------------------------------------- the ticks
-- The two checklist lines that have been asking about this since 0040 can now
-- answer for themselves.
create or replace function app.tick_system_access(p_person_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.plan_tasks pt
     set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), pt.done_by)
    from public.plans p
   where pt.plan_id = p.id and pt.task_key = 'system_access' and pt.status in ('open', 'blocked')
     and p.person_id = p_person_id and p.kind = 'onboarding' and p.status = 'in_progress'
     and exists (select 1 from public.person_access pa
                  where pa.person_id = p_person_id and pa.status = 'granted');
end $$;

-- ...and its opposite, which needs one more condition to stay honest: a
-- person who never had anything recorded has not had it "removed", and
-- ticking that line for them would be the checklist lying to whoever reads it.
create or replace function app.tick_access_removed(p_person_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.plan_tasks pt
     set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), pt.done_by)
    from public.plans p
   where pt.plan_id = p.id and pt.task_key = 'access_removed' and pt.status in ('open', 'blocked')
     and p.person_id = p_person_id and p.kind = 'offboarding' and p.status = 'in_progress'
     and exists (select 1 from public.person_access pa where pa.person_id = p_person_id)
     and not exists (select 1 from public.person_access pa
                      where pa.person_id = p_person_id and pa.status = 'granted');
end $$;

-- ---------------------------------------------------------------- grants
-- `app.can_view_access` is what the row policy asks, so it stays executable by
-- the role the policy runs as; the rest are called only from the definer
-- functions above.
revoke all on function app.can_manage_access(uuid, uuid),
  app.tick_system_access(uuid), app.tick_access_removed(uuid) from public;
revoke all on function public.grant_access(jsonb), public.revoke_access(uuid, text) from public, anon;
grant execute on function public.grant_access(jsonb), public.revoke_access(uuid, text) to authenticated;
