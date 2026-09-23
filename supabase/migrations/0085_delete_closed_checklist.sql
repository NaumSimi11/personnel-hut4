-- 0085_delete_closed_checklist.sql
-- Clearing a closed checklist (plan 066).
--
-- task.md, describing the ordinary shape of a life here: "employe, offboard,
-- close, open, rehire, remove from closed. this is uusial scenarion, and we
-- need to be able to delete the logs that are in the Close section in the
-- offboarding."
--
-- Somebody joins, leaves, and comes back. The offboarding that closed behind
-- them is still sitting in the Closed section of the queue, describing a
-- departure that has since been undone by their return — and on a queue HR
-- reads every week, that is noise with no way to clear it.
--
-- Two parts: something to delete with, and one foreign key that would have
-- stopped it.

-- ------------------------------------------------------------- the key
-- The starter kit opens an IT request against the checklist line it belongs
-- to (0042), and that reference was NO ACTION — so any onboarding that ever
-- ordered a laptop could never be deleted. The other two references from a
-- plan already SET NULL (`generated_documents.plan_id`,
-- `handover_sends.plan_id`), and for the same reason: the document and the
-- handover are real things that outlive the checklist that asked for them.
--
-- An IT request is the same kind of thing. "Set up a laptop" is work somebody
-- in IT is doing; it should survive the checklist being cleared, not hold it
-- hostage. So it joins them.
alter table public.it_requests
  drop constraint it_requests_plan_task_id_fkey,
  add constraint it_requests_plan_task_id_fkey
    foreign key (plan_task_id) references public.plan_tasks(id) on delete set null;

-- ------------------------------------------------------------ delete_plan
-- A checklist that is finished or cancelled may be cleared away. One that is
-- still running may not: it is somebody's open work, and the way to stop it is
-- to cancel the departure or complete the plan, which both say what happened.
create or replace function public.delete_plan(p_plan_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_plan record;
  v_name text;
  v_tasks int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_plan from public.plans where id = p_plan_id for update;
  if not found then
    raise exception 'That checklist no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_plan.company_id, 'tasks.assign') then
    raise exception 'Clearing a checklist needs "Assign onboarding tasks" in this company.'
      using errcode = '42501';
  end if;
  if v_plan.status = 'in_progress' then
    raise exception 'This checklist is still running. Complete it, or cancel the departure, before clearing it.'
      using errcode = '22023';
  end if;

  select full_name into v_name from public.people where id = v_plan.person_id;
  select count(*) into v_tasks from public.plan_tasks where plan_id = p_plan_id;

  -- The lines go with it (they are the checklist). What was produced along the
  -- way does not: the generated documents and handover sends keep their own
  -- rows and lose only the pointer, and so now do the IT requests.
  delete from public.plans where id = p_plan_id;

  return jsonb_build_object('deleted', true, 'kind', v_plan.kind,
                            'person', coalesce(v_name, 'Somebody'), 'lines', v_tasks);
end $$;

revoke all on function public.delete_plan(uuid) from public, anon;
grant execute on function public.delete_plan(uuid) to authenticated;
