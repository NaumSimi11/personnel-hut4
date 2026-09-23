-- 0076_person_access_fixes.sql
-- Five corrections to 0075, found in review before anybody used it. 0075 is
-- already on live, so they arrive as their own migration rather than as edits
-- to a file the database has seen.
--
-- 1. Both ticks matched `person_access` across EVERY company while ticking a
--    single company's plan. So an old revoked row at another company ticked
--    "Accounts and access removed" — exactly the lie 0075's own comment set
--    out to prevent — and a live grant at another company ticked "System
--    access granted" on a new employer's checklist.
-- 2. `revoke_access` wrote its note into the same column as the grant-time
--    one, destroying the "where to go to remove it" sentence at the moment
--    somebody needed it most.
-- 3. The app could not tell whether the viewer may manage a person's access:
--    the rule includes being their manager, which the browser has no way to
--    know. It has to ask.
-- 4. `access_systems` carries an `admin_write` policy but only ever granted
--    SELECT, so on a database without Supabase's default privileges an admin
--    could not rename or retire a system at all.

-- ---------------------------------------------------------------- the note
alter table public.person_access add column revoked_note text
  check (revoked_note is null or length(revoked_note) <= 1000);
comment on column public.person_access.revoked_note is
  'Why it was shut down. Separate from `note`, which says how it was given.';

-- --------------------------------------------------------------- the grant
grant insert, update, delete on public.access_systems to authenticated;

-- --------------------------------------------------------------- the ticks
-- Scoped to the plan's own company. A person employed in two places has two
-- sets of accounts, and leaving one says nothing about the other.
create or replace function app.tick_system_access(p_person_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.plan_tasks pt
     set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), pt.done_by)
    from public.plans p
   where pt.plan_id = p.id and pt.task_key = 'system_access' and pt.status in ('open', 'blocked')
     and p.person_id = p_person_id and p.kind = 'onboarding' and p.status = 'in_progress'
     and exists (select 1 from public.person_access pa
                  where pa.person_id = p_person_id and pa.company_id = p.company_id
                    and pa.status = 'granted');
end $$;

create or replace function app.tick_access_removed(p_person_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.plan_tasks pt
     set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), pt.done_by)
    from public.plans p
   where pt.plan_id = p.id and pt.task_key = 'access_removed' and pt.status in ('open', 'blocked')
     and p.person_id = p_person_id and p.kind = 'offboarding' and p.status = 'in_progress'
     -- Something was recorded HERE, and none of it is live any more.
     and exists (select 1 from public.person_access pa
                  where pa.person_id = p_person_id and pa.company_id = p.company_id)
     and not exists (select 1 from public.person_access pa
                      where pa.person_id = p_person_id and pa.company_id = p.company_id
                        and pa.status = 'granted');
end $$;

-- ------------------------------------------------------------ revoke_access
-- The reason for shutting it down goes in its own column now.
create or replace function public.revoke_access(p_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_row record;
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
         revoked_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_id;
  perform app.tick_access_removed(v_row.person_id);
  return jsonb_build_object('id', v_row.id, 'system', v_row.label, 'already', false);
end $$;

-- -------------------------------------------------------- my_access_rights
-- What the viewer may do here, answered by the same helpers the writes use.
-- The browser cannot work this out for itself: "is the manager named on this
-- person's employment" is not something the session knows.
create or replace function public.my_access_rights(p_person_id uuid, p_company_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'may_view', app.can_view_access(p_person_id, p_company_id),
    'may_manage', app.can_manage_access(p_person_id, p_company_id)
  )
$$;

revoke all on function public.my_access_rights(uuid, uuid) from public, anon;
grant execute on function public.my_access_rights(uuid, uuid) to authenticated;
