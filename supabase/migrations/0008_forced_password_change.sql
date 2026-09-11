-- 0008_forced_password_change.sql
-- Invite-flow enforcement (ported from the Hut4 leave system's design): while
-- an account is on a temporary password, the app must refuse everything except
-- changing that password. There the server middleware enforced it; here RLS
-- does. The flag lives in auth app_metadata (admin-API-writable ONLY — a user
-- cannot clear it themselves, unlike user_metadata) and arrives in every JWT.
--
-- Gating happens in the security-helper primitives, so every policy built on
-- them inherits it. Deliberate exception: reference vocabularies with
-- `using (true)` SELECT policies (capabilities, companies, lookups) stay
-- readable — they contain no personal data, and the change-password screen
-- needs no data at all.

create or replace function app.password_change_pending() returns boolean
language sql stable as $$
  select coalesce(((auth.jwt()->'app_metadata')->>'must_change_password')::boolean, false)
$$;
grant execute on function app.password_change_pending() to authenticated, anon;

create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select (not app.password_change_pending()) and exists (
    select 1 from public.platform_admins
    where person_id = (select id from public.people where user_id = auth.uid())
  )
$$;

create or replace function app.is_self(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (not app.password_change_pending())
     and p is not null and p = app.current_person_id()
$$;

create or replace function app.has_capability(target_company uuid, cap text) returns boolean
language sql stable security definer set search_path = public as $$
  select (not app.password_change_pending()) and (
    app.is_admin() or exists (
      select 1
      from public.access_grants g
      join public.grant_capabilities gc on gc.grant_id = g.id
      where g.person_id = app.current_person_id()
        and g.company_id = target_company
        and gc.capability_key = cap
    )
  )
$$;

create or replace function app.has_capability_anywhere(cap text) returns boolean
language sql stable security definer set search_path = public as $$
  select (not app.password_change_pending()) and (
    app.is_admin() or exists (
      select 1 from public.access_grants g
      join public.grant_capabilities gc on gc.grant_id = g.id
      where g.person_id = app.current_person_id() and gc.capability_key = cap
    )
  )
$$;

create or replace function app.in_company(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (not app.password_change_pending()) and (
    app.is_admin()
    or exists (select 1 from public.employment_periods ep
               join public.employment_statuses es on es.key = ep.status
               where ep.company_id = c and ep.person_id = app.current_person_id()
                 and es.counts_as_employed)
    or exists (select 1 from public.access_grants g
               where g.company_id = c and g.person_id = app.current_person_id())
  )
$$;

create or replace function app.is_project_member(project uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (not app.password_change_pending()) and exists (
    select 1 from public.external_project_members m
    where m.project_id = project and m.person_id = app.current_person_id())
$$;

create or replace function app.can_view_compensation(period uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (not app.password_change_pending()) and exists (
    select 1 from public.employment_periods ep
    where ep.id = period
      and (ep.person_id = app.current_person_id()
           or app.has_capability(ep.company_id, 'salary.view')))
$$;
