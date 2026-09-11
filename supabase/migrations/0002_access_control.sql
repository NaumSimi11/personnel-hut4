-- 0002_access_control.sql
-- The permission model: capability catalog (data, not code), presets,
-- per-person × per-company grants, platform admins, and the SECURITY DEFINER
-- helpers every RLS policy is built on.
-- Capability keys are shared vocabulary with the design prototype
-- (prototype/app.js `groups`) so design and production speak the same names.

-- ------------------------------------------------------------- capabilities
create table public.capabilities (
  key text primary key,                 -- e.g. 'salary.view'
  group_name text not null,             -- e.g. 'Compensation & payroll'
  label text not null,
  sensitive boolean not null default false,
  sort_order int not null default 0,
  archived_at timestamptz
);

-- Selecting an action capability requires its viewing prerequisites
-- (prototype `dependencies`); enforced app-side on grant editing, kept here
-- as the single source of truth.
create table public.capability_dependencies (
  capability_key text not null references public.capabilities(key),
  requires_key text not null references public.capabilities(key),
  primary key (capability_key, requires_key),
  check (capability_key <> requires_key)
);

-- ------------------------------------------------------------------ presets
-- Starting configurations, not roles: applying one copies capabilities into
-- the grant; later preset edits never silently change existing grants.
create table public.permission_presets (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id),  -- NULL = shared preset
  name text not null,
  description text,
  is_system boolean not null default false,
  archived_at timestamptz,
  unique nulls not distinct (company_id, name)
);

create table public.preset_capabilities (
  preset_id uuid not null references public.permission_presets(id) on delete cascade,
  capability_key text not null references public.capabilities(key),
  primary key (preset_id, capability_key)
);

-- ------------------------------------------------------------------- grants
-- One grant per person per company; capabilities are rows so adding one is
-- an INSERT and the audit trigger records exactly what changed.
create table public.access_grants (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id),
  company_id uuid not null references public.companies(id),
  source_preset_id uuid references public.permission_presets(id),
  granted_by uuid references public.people(id),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (person_id, company_id)
);
create trigger touch before update on public.access_grants
  for each row execute function app.touch_updated_at();

create table public.grant_capabilities (
  grant_id uuid not null references public.access_grants(id) on delete cascade,
  capability_key text not null references public.capabilities(key),
  primary key (grant_id, capability_key)
);

-- ---------------------------------------------------------- platform admins
-- Admin is a separate explicit grant (blueprint §3), holding-wide.
create table public.platform_admins (
  person_id uuid primary key references public.people(id),
  granted_by uuid references public.people(id),
  granted_at timestamptz not null default now()
);

-- Never remove the last recovery-capable admin (blueprint §3).
create or replace function app.prevent_last_admin_removal() returns trigger
language plpgsql as $$
begin
  if (select count(*) from public.platform_admins) <= 1 then
    raise exception 'Cannot remove the last platform admin';
  end if;
  return old;
end $$;
create trigger keep_last_admin before delete on public.platform_admins
  for each row execute function app.prevent_last_admin_removal();

-- ------------------------------------------------------------- RLS helpers
-- SECURITY DEFINER so policies on access tables can call them without
-- recursing into their own policies.
create or replace function app.current_person_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.people where user_id = auth.uid()
$$;

create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.platform_admins
    where person_id = (select id from public.people where user_id = auth.uid())
  )
$$;

-- The single question every policy asks: may the current user do `cap`
-- inside `target_company`? Default deny; no scope ever expands to sibling
-- companies (blueprint §3 permission semantics).
create or replace function app.has_capability(target_company uuid, cap text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or exists (
    select 1
    from public.access_grants g
    join public.grant_capabilities gc on gc.grant_id = g.id
    where g.person_id = app.current_person_id()
      and g.company_id = target_company
      and gc.capability_key = cap
  )
$$;

-- Convenience: is `p` the signed-in person (self-access rules)?
create or replace function app.is_self(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p is not null and p = app.current_person_id()
$$;

grant usage on schema app to authenticated, anon, service_role;
grant execute on function app.current_person_id() to authenticated;
grant execute on function app.is_admin() to authenticated;
grant execute on function app.has_capability(uuid, text) to authenticated;
grant execute on function app.is_self(uuid) to authenticated;
