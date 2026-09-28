-- 0087_delete_person_anyway.sql
-- Deleting a person who WAS somebody (plan 067).
--
-- 0084 deletes a record that was a mistake and refuses anyone with history,
-- for the reason written there: the history is worth keeping. That is still
-- the default. What was missing is the answer for when it is not: a test
-- person, a walkthrough that left twenty rows behind, an import somebody
-- regrets. Archiving them files the mess forever.
--
-- So `p_force`, the way 0082 did it for applications. Off, this behaves
-- exactly as 0084 did. On, it takes everything that is ABOUT the person and
-- unlinks everything they merely TOUCHED:
--
--   - Rows about them go: employments and all that hangs off one, leave,
--     their documents, kudos received and given, tasks and checklists for
--     them, equipment records, access, signatures, policy acknowledgements.
--   - Rows about something else stay and forget who: every "approved by",
--     "uploaded by", "manager", "owner", "assignee" column becomes null, as
--     the activity log already does for a deleted actor.
--   - Two "who" columns cannot be null. A task somebody else still has to do
--     and an equipment handover already under way are reassigned to the admin
--     doing the delete, rather than vanishing from under the other person.
--
-- The foreign keys are not rewritten to cascade. Admins may delete a people
-- row directly under RLS, and a cascade would turn that stray delete into a
-- silent wipe. This stays the one door, and it says what it costs first:
-- `person_delete_cost` is what the confirmation shows BEFORE the click.
--
-- The sign-in is not handled here: SQL cannot reach auth. The app removes the
-- account through the server first, `people.user_id` goes null by its key,
-- and the gate below is then satisfied honestly.

-- What a forced delete takes, counted the way the confirmation says it.
create or replace function public.person_delete_cost(p_person_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'employments', (select count(*) from public.employment_periods where person_id = p_person_id),
    'leave_requests', (select count(*) from public.leave_requests where person_id = p_person_id),
    'documents', (select count(*) from public.documents where person_id = p_person_id),
    'kudos', (select count(*) from public.kudos where to_person_id = p_person_id or from_person_id = p_person_id),
    'tasks', (select count(*) from public.tasks where person_id = p_person_id),
    'equipment',
      (select count(*) from public.asset_assignments where person_id = p_person_id)
      + (select count(*) from public.asset_handovers where counterparty_id = p_person_id),
    'checklists', (select count(*) from public.plans where person_id = p_person_id),
    'has_sign_in', (select user_id is not null from public.people where id = p_person_id)
  )
  where app.is_admin()
$$;

-- Everything that goes with the person, children before parents. Kept apart
-- from the gate so the order is readable on its own.
create or replace function app.delete_person_history(p_person_id uuid, p_actor uuid)
returns text[]
language plpgsql security definer set search_path = public as $$
declare
  v_periods uuid[];
  v_docs uuid[];
  v_paths text[];
begin
  select coalesce(array_agg(id), '{}') into v_periods from public.employment_periods where person_id = p_person_id;
  select coalesce(array_agg(id), '{}') into v_docs from public.documents where person_id = p_person_id;
  select coalesce(array_agg(storage_path), '{}') into v_paths from public.documents where person_id = p_person_id;

  -- 1. Rows about something else forget who.
  update public.companies set director_person_id = null where director_person_id = p_person_id;
  update public.companies set hr_contact_person_id = null where hr_contact_person_id = p_person_id;
  update public.employment_periods set manager_id = null where manager_id = p_person_id;
  update public.employment_departure_details set recorded_by = null where recorded_by = p_person_id;
  update public.compensation_records set approved_by = null where approved_by = p_person_id;
  update public.compensation_records set proposed_by = null where proposed_by = p_person_id;
  update public.access_grants set granted_by = null where granted_by = p_person_id;
  update public.platform_admins set granted_by = null where granted_by = p_person_id;
  update public.hiring_requests set decided_by = null where decided_by = p_person_id;
  update public.hiring_requests set hiring_manager_id = null where hiring_manager_id = p_person_id;
  update public.hiring_requests set requested_by = null where requested_by = p_person_id;
  update public.hiring_request_history set actor_id = null where actor_id = p_person_id;
  update public.jobs set closed_by = null where closed_by = p_person_id;
  update public.job_channels set published_by = null where published_by = p_person_id;
  update public.job_channels set verified_by = null where verified_by = p_person_id;
  update public.candidates set do_not_contact_by = null where do_not_contact_by = p_person_id;
  update public.candidates set sourced_by = null where sourced_by = p_person_id;
  update public.candidate_files set uploaded_by = null where uploaded_by = p_person_id;
  update public.candidate_notes set actor_id = null where actor_id = p_person_id;
  update public.applications set owner_id = null where owner_id = p_person_id;
  update public.application_events set actor_id = null where actor_id = p_person_id;
  update public.application_files set uploaded_by = null where uploaded_by = p_person_id;
  update public.interviews set created_by = null where created_by = p_person_id;
  update public.offers set approved_by = null where approved_by = p_person_id;
  update public.offers set created_by = null where created_by = p_person_id;
  update public.promotions set drafted_by = null where drafted_by = p_person_id;
  update public.promotions set published_by = null where published_by = p_person_id;
  update public.promotions set requested_by = null where requested_by = p_person_id;
  update public.promotions set reviewed_by = null where reviewed_by = p_person_id;
  update public.plans set hr_owner_id = null where hr_owner_id = p_person_id;
  update public.plan_tasks set done_by = null where done_by = p_person_id;
  update public.plan_tasks set owner_id = null where owner_id = p_person_id;
  update public.documents set uploaded_by = null where uploaded_by = p_person_id;
  update public.document_requests set reviewer_id = null where reviewer_id = p_person_id;
  update public.policies set published_by = null where published_by = p_person_id;
  update public.contract_templates set published_by = null where published_by = p_person_id;
  update public.asset_assignments set issued_by = null where issued_by = p_person_id;
  update public.asset_notes set about_person_id = null where about_person_id = p_person_id;
  update public.asset_notes set written_by = null where written_by = p_person_id;
  update public.asset_handovers set from_person_id = null where from_person_id = p_person_id;
  update public.asset_handovers set to_person_id = null where to_person_id = p_person_id;
  update public.asset_handovers set signed_by_counterparty = null where signed_by_counterparty = p_person_id;
  update public.it_requests set assignee_id = null where assignee_id = p_person_id;
  update public.it_requests set requested_by = null where requested_by = p_person_id;
  update public.payroll_periods set approved_by = null where approved_by = p_person_id;
  update public.payroll_periods set prepared_by = null where prepared_by = p_person_id;
  update public.payroll_items set created_by = null where created_by = p_person_id;
  update public.integrations set authorized_by = null where authorized_by = p_person_id;
  update public.workflow_owners set person_id = null where person_id = p_person_id;
  update public.employment_changes set created_by = null where created_by = p_person_id;
  update public.employment_corrections set corrected_by = null where corrected_by = p_person_id;
  update public.employment_corrections set new_manager_id = null where new_manager_id = p_person_id;
  update public.employment_corrections set old_manager_id = null where old_manager_id = p_person_id;
  update public.leave_adjustments set created_by = null where created_by = p_person_id;
  update public.leave_requests set submitted_by = null where submitted_by = p_person_id;
  update public.leave_requests set decided_by = null where decided_by = p_person_id;
  update public.leave_requests set cancelled_by = null where cancelled_by = p_person_id;
  update public.leave_requests set cancellation_declined_by = null where cancellation_declined_by = p_person_id;
  update public.leave_corrections set corrected_by = null where corrected_by = p_person_id;
  update public.kudos set posted_by = null where posted_by = p_person_id;
  update public.handover_recipients set person_id = null where person_id = p_person_id;
  update public.handover_sends set marked_by = null where marked_by = p_person_id;
  update public.generated_documents set requested_by = null where requested_by = p_person_id;
  update public.tasks set done_by = null where done_by = p_person_id;
  update public.task_people set added_by = null where added_by = p_person_id;
  update public.person_access set granted_by = null where granted_by = p_person_id;
  update public.person_access set revoked_by = null where revoked_by = p_person_id;
  -- The two that cannot be null: somebody else's task, a handover under way.
  update public.tasks set created_by = p_actor where created_by = p_person_id;
  update public.asset_handovers set started_by = p_actor where started_by = p_person_id;

  -- 2. Rows about them go, children first.
  delete from public.task_people where person_id = p_person_id;
  delete from public.tasks where person_id = p_person_id;
  delete from public.kudos where to_person_id = p_person_id or from_person_id = p_person_id;
  delete from public.scorecards where author_id = p_person_id;
  delete from public.interview_panel where person_id = p_person_id;
  delete from public.policy_acknowledgements where person_id = p_person_id;
  delete from public.signatures where person_id = p_person_id;
  delete from public.it_requests where person_id = p_person_id;
  delete from public.external_project_members where person_id = p_person_id;
  delete from public.leave_links where person_id = p_person_id;
  delete from public.person_access where person_id = p_person_id;
  delete from public.access_grants where person_id = p_person_id;
  delete from public.platform_admins where person_id = p_person_id;
  delete from public.asset_handovers where counterparty_id = p_person_id;
  delete from public.asset_assignments where person_id = p_person_id;
  delete from public.leave_corrections where person_id = p_person_id;
  delete from public.leave_requests where person_id = p_person_id;
  delete from public.leave_balances where person_id = p_person_id;
  delete from public.payroll_items where person_id = p_person_id;
  delete from public.payroll_lines where person_id = p_person_id;
  delete from public.compensation_records where employment_period_id = any(v_periods);
  -- Their documents: whatever points at one lets go first.
  update public.promotions set creative_document_id = null where creative_document_id = any(v_docs);
  update public.plan_tasks set evidence_document_id = null where evidence_document_id = any(v_docs);
  update public.document_requests set fulfilled_document_id = null where fulfilled_document_id = any(v_docs);
  update public.payroll_periods set export_document_id = null where export_document_id = any(v_docs);
  update public.asset_handovers set document_id = null where document_id = any(v_docs);
  update public.documents set supersedes_id = null where supersedes_id = any(v_docs);
  delete from public.documents where person_id = p_person_id;
  delete from public.document_requests where person_id = p_person_id;
  delete from public.plans where person_id = p_person_id;
  delete from public.employment_corrections where person_id = p_person_id;
  update public.applications set employment_period_id = null where employment_period_id = any(v_periods);
  update public.employment_periods set transferred_to_period_id = null where transferred_to_period_id = any(v_periods);
  delete from public.employment_periods where person_id = p_person_id;
  -- Private details, notifications, handover sends and generated documents
  -- cascade with the row itself (0084), and the activity log forgets the actor.
  return v_paths;
end $$;

-- 0082 learned that an overload makes the RPC ambiguous from PostgREST.
drop function if exists public.delete_person(uuid);

create or replace function public.delete_person(p_person_id uuid, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_person record;
  v_constraint text;
  v_cost jsonb;
  v_paths text[] := '{}';
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
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
  -- longer knows who they are. The app takes the account off first.
  if v_person.user_id is not null then
    raise exception '% still has a sign-in. Remove their access first, then delete the record.',
      v_person.full_name using errcode = '22023';
  end if;
  v_cost := public.person_delete_cost(p_person_id);

  if coalesce(p_force, false) then
    v_paths := app.delete_person_history(p_person_id, v_me);
  else
    if exists (select 1 from public.employment_periods ep where ep.person_id = p_person_id) then
      raise exception '% has an employment on record, so they are somebody this company employed. Archive them instead.',
        v_person.full_name using errcode = '22023';
    end if;
    if exists (select 1 from public.activity_log al where al.actor_person_id = p_person_id) then
      raise exception '% has acted in this system, and the trail would forget who. Archive them instead.',
        v_person.full_name using errcode = '22023';
    end if;
  end if;

  begin
    delete from public.people where id = p_person_id;
  exception when foreign_key_violation then
    get stacked diagnostics v_constraint = constraint_name;
    raise exception '% still has % on record. Archive them instead.',
      v_person.full_name, app.person_delete_blocker(v_constraint) using errcode = '22023';
  end;

  return jsonb_build_object('deleted', true, 'name', v_person.full_name, 'cost', v_cost, 'storage_paths', to_jsonb(v_paths));
end $$;

revoke all on function app.delete_person_history(uuid, uuid) from public;
revoke all on function public.person_delete_cost(uuid) from public, anon;
revoke all on function public.delete_person(uuid, boolean) from public, anon;
grant execute on function public.person_delete_cost(uuid) to authenticated;
grant execute on function public.delete_person(uuid, boolean) to authenticated;
