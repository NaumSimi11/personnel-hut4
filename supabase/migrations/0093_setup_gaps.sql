-- 0093_setup_gaps.sql
-- What is missing for the app to work (plan 073). Two workflow roles carry
-- real work and nobody had them: on 2026-10-09 not one of the six companies
-- had an IT owner or an HR owner, nor an IT or HR inbox.
--
--   * it_owner — owns the IT lines of every onboarding checklist (0077: an
--     "it" line goes to this person), is told of every IT request (0041), and
--     is the address of a handover sent "to the IT owner". Missing: those
--     lines belong to nobody and the requests reach nobody.
--   * hr_owner — is told when an IT request is blocked (0041). Missing:
--     nobody hears.
--   * the IT and HR inboxes — softer: without them the mail goes to the
--     owner's own address.
--
-- An owner who has been archived counts as missing. setup_gaps() answers for
-- the companies the viewer looks after: every company for a platform admin,
-- the ones where they hold employment.edit (Company HR) otherwise; nobody
-- else is told. Only admins can set owners and inboxes (0006 admin_write), so
-- `can_fix` tells the page whether to offer the link.

begin;

-- An owner set and not archived.
create or replace function app.has_live_owner(p_company_id uuid, p_role text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.workflow_owners w join public.people p on p.id = w.person_id
                  where w.company_id = p_company_id and w.role_key = p_role and p.archived_at is null)
$$;

create or replace function public.setup_gaps() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin boolean := app.is_admin();
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'can_fix', v_admin,
    'companies', coalesce((
      select jsonb_agg(g order by g->>'company_name')
        from (
          select jsonb_build_object(
                   'company_id', c.id,
                   'company_name', c.name,
                   'missing_roles', to_jsonb(array_remove(array[
                     case when not app.has_live_owner(c.id, 'it_owner') then 'it_owner' end,
                     case when not app.has_live_owner(c.id, 'hr_owner') then 'hr_owner' end], null)),
                   'missing_inboxes', to_jsonb(array_remove(array[
                     case when nullif(btrim(coalesce(c.it_notification_email, '')), '') is null then 'it' end,
                     case when nullif(btrim(coalesce(c.hr_notification_email, '')), '') is null then 'hr' end], null))) as g
            from public.companies c
           where v_admin or app.has_capability(c.id, 'employment.edit')
        ) x
       where jsonb_array_length(g->'missing_roles') > 0 or jsonb_array_length(g->'missing_inboxes') > 0), '[]'::jsonb));
end $$;

-- ----------------------------------------------- the owner takes the lines
-- A checklist line's owner is resolved when the checklist starts (0077), so
-- the IT lines of every onboarding begun while a company had no IT owner sat
-- with nobody — and would have stayed so after one was named. Naming (or
-- changing) the IT owner hands them the company's open IT lines that still
-- have nobody; a line somebody already has is left with them.
create or replace function app.it_owner_takes_open_lines() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role_key = 'it_owner' then
    update public.plan_tasks t
       set owner_id = new.person_id
      from public.plans p
     where p.id = t.plan_id and p.company_id = new.company_id
       and t.owner_role = 'it' and t.owner_id is null and t.status in ('open', 'blocked');
  end if;
  return new;
end $$;
create trigger t5_it_owner_takes_open_lines after insert or update of person_id on public.workflow_owners
  for each row execute function app.it_owner_takes_open_lines();

revoke all on function app.it_owner_takes_open_lines() from public;
revoke all on function app.has_live_owner(uuid, text) from public;
revoke all on function public.setup_gaps() from public, anon;
grant execute on function public.setup_gaps() to authenticated;

commit;
