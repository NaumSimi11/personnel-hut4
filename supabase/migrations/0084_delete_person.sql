-- 0084_delete_person.sql
-- Deleting a person who was never anybody (plan 065).
--
-- task.md: "we need to be bale also to delete ppl / archived / delete."
--
-- The directory has archived rather than deleted since `8c68a31`, for a good
-- reason written down at the time: of the 98 foreign keys pointing at
-- `people`, **93 block a delete**. Anyone with an employment, a leave request,
-- a document, a kudos or a signature simply cannot be removed, and the history
-- that blocks it is history worth keeping. Archive is the right answer for
-- them and stays.
--
-- What archive is the wrong answer for is the row that was a mistake: a name
-- typed twice, a test record, an import that ran against the wrong file. That
-- person has no history to protect, and leaving them archived forever is
-- filing a typo.
--
-- So this deletes, and leans on those 93 keys rather than restating them: the
-- explicit checks below cover the cases worth naming, and anything else the
-- database refuses is turned from `violates foreign key constraint
-- "leave_requests_person_id_fkey"` into a sentence about leave.
--
-- Four things DO cascade, and all four should: their notifications, their
-- queued documents, the handover sends about them, and their private details —
-- the national ID and bank account, which is precisely the record that should
-- not outlive the person it describes.

-- Which table a refusal came from, in words. Used only to explain a refusal,
-- so an unmapped table degrades to its own name rather than to nothing.
create or replace function app.person_delete_blocker(p_constraint text) returns text
language sql immutable as $$
  select case
    when p_constraint like 'employment%' then 'an employment record'
    when p_constraint like 'leave%' then 'leave records'
    when p_constraint like 'payroll%' then 'payroll records'
    when p_constraint like 'document%' then 'documents'
    when p_constraint like 'asset%' then 'equipment records'
    when p_constraint like 'kudos%' then 'kudos'
    when p_constraint like 'plan%' then 'a checklist'
    when p_constraint like 'task%' then 'tasks'
    when p_constraint like 'access_grants%' then 'access grants'
    when p_constraint like 'person_access%' then 'recorded system access'
    when p_constraint like 'policy_ack%' then 'policies they acknowledged'
    when p_constraint like 'signature%' then 'something they signed'
    when p_constraint like 'compensation%' then 'compensation records'
    when p_constraint like 'companies%' then 'a company naming them as director or HR contact'
    when p_constraint like 'workflow_owners%' then 'a workflow they own'
    when p_constraint like 'it_request%' then 'IT requests'
    when p_constraint like 'hiring%' or p_constraint like 'job%' or p_constraint like 'offer%'
      or p_constraint like 'interview%' or p_constraint like 'scorecard%'
      or p_constraint like 'application%' or p_constraint like 'candidate%'
      or p_constraint like 'promotion%' then 'recruitment history'
    else 'records elsewhere'
  end
$$;

create or replace function public.delete_person(p_person_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_person record;
  v_constraint text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  -- The same gate the archive has: this is the directory's most destructive
  -- act, and it is not delegated.
  if not app.is_admin() then
    raise exception 'Only platform admins delete people.' using errcode = '42501';
  end if;
  select * into v_person from public.people where id = p_person_id for update;
  if not found then
    raise exception 'That person no longer exists.' using errcode = '22023';
  end if;
  if p_person_id = v_me then
    raise exception 'You cannot delete yourself.' using errcode = '22023';
  end if;
  -- An account outliving its person can still sign in, to an app that no
  -- longer knows who they are. Access comes off first, through the door that
  -- already exists for it.
  if v_person.user_id is not null then
    raise exception '% still has a sign-in. Remove their access first, then delete the record.',
      v_person.full_name using errcode = '22023';
  end if;
  -- Named before the generic refusal, because "they work here" is the answer
  -- somebody is most likely to need.
  if exists (select 1 from public.employment_periods ep where ep.person_id = p_person_id) then
    raise exception '% has an employment on record, so they are somebody this company employed. Archive them instead.',
      v_person.full_name using errcode = '22023';
  end if;
  -- Their own actions would become "system" in the trail (activity_log sets
  -- the actor null), which quietly rewrites who did what.
  if exists (select 1 from public.activity_log al where al.actor_person_id = p_person_id) then
    raise exception '% has acted in this system, and the trail would forget who. Archive them instead.',
      v_person.full_name using errcode = '22023';
  end if;

  begin
    delete from public.people where id = p_person_id;
  exception when foreign_key_violation then
    get stacked diagnostics v_constraint = constraint_name;
    raise exception '% still has % on record. Archive them instead.',
      v_person.full_name, app.person_delete_blocker(v_constraint) using errcode = '22023';
  end;

  return jsonb_build_object('deleted', true, 'name', v_person.full_name);
end $$;

revoke all on function app.person_delete_blocker(text) from public;
revoke all on function public.delete_person(uuid) from public, anon;
grant execute on function public.delete_person(uuid) to authenticated;
