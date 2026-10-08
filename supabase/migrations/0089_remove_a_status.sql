-- 0089_remove_a_status.sql
-- Removing a hiring status (plan 069). 0088 let an admin add, rename, retire
-- and restore statuses; retiring left every application that had one where
-- it was. HR wants to take a status away and say where its applications go
-- — "Interview 4" folded into "Interview 3" — or delete one that was a typo.
--
-- Two doors, both admin-only (the Labels page is):
--   * sub_status_usage(key): how many applications carry it now, and how many
--     timeline entries mention it — what the confirmation says before the click;
--   * remove_sub_status(key, move_to): moves its applications to another live
--     status of the same stage (or leaves them, when move_to is null), then
--     deletes the status if nothing ever used it and retires it otherwise, so
--     old timelines still read "Interview 4" rather than a raw key. The house
--     rule: delete is for a mistake, archive is for history (0080).
--
-- The four statuses the rules name (0088) cannot be removed; renaming them is
-- the way. One transaction per call, all or nothing.

begin;

-- ------------------------------------------------------------------ usage
create or replace function public.sub_status_usage(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_admin() then
    raise exception 'Only platform admins manage hiring statuses.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.application_sub_statuses where key = p_key) then
    raise exception 'That status no longer exists.' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'applications', (select count(*) from public.applications where sub_status_key = p_key),
    'history', (select count(*) from public.application_events
                 where from_sub_status_key = p_key or to_sub_status_key = p_key));
end $$;

-- ----------------------------------------------------------------- remove
-- The move is housekeeping, not anybody's work on a candidate. Each
-- application gets its timeline line (so its page says why the status
-- changed), but the candidate's last activity does not move and the audit
-- trail gets one summary row instead of one per application — the 0088
-- backfill's discipline, with its triggers off for the move only. The stored
-- reason on a Rejected or Withdrawn row follows the status when it was only
-- the old status's name, as in set_application_status.
create or replace function public.remove_sub_status(p_key text, p_move_to text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_from record;
  v_to_key text;
  v_to_label text;
  v_move text := nullif(trim(coalesce(p_move_to, '')), '');
  v_n int := 0;
  v_outcome text;
begin
  if not app.is_admin() then
    raise exception 'Only platform admins manage hiring statuses.' using errcode = '42501';
  end if;
  select s.key, s.stage_key, s.label, s.archived_at into v_from
    from public.application_sub_statuses s where s.key = p_key
     for update;
  if not found then
    raise exception 'That status no longer exists.' using errcode = '22023';
  end if;
  if v_from.key in ('applied', 'sourced', 'contact_attempted', 'contacted') then
    raise exception '"%" is used by the pipeline''s own rules — rename it instead.', v_from.label
      using errcode = '22023';
  end if;

  if v_move is not null then
    select s.key, s.label into v_to_key, v_to_label
      from public.application_sub_statuses s
     where s.key = v_move and s.stage_key = v_from.stage_key and s.archived_at is null and s.key <> v_from.key;
    if not found then
      raise exception 'Pick another live status of the same stage to move its applications to.'
        using errcode = '22023';
    end if;
    alter table public.applications disable trigger audit;
    alter table public.application_events disable trigger t8_touch_candidate;
    insert into public.application_events
      (application_id, actor_id, kind, body, from_sub_status_key, to_sub_status_key)
      select a.id, v_me,
             case when a.stage_key in ('new', 'screening') then 'outreach' else 'status_change' end,
             format('Status "%s" removed.', v_from.label), v_from.key, v_to_key
        from public.applications a
       where a.sub_status_key = v_from.key;
    get diagnostics v_n = row_count;
    update public.applications a
       set sub_status_key = v_to_key,
           rejected_reason = case
             when a.stage_key = 'rejected'
              and (btrim(coalesce(a.rejected_reason, '')) = '' or lower(btrim(a.rejected_reason)) = lower(btrim(v_from.label)))
             then v_to_label else a.rejected_reason end,
           withdrawn_reason = case
             when a.stage_key = 'withdrawn'
              and (btrim(coalesce(a.withdrawn_reason, '')) = '' or lower(btrim(a.withdrawn_reason)) = lower(btrim(v_from.label)))
             then v_to_label else a.withdrawn_reason end
     where a.sub_status_key = v_from.key;
    alter table public.application_events enable trigger t8_touch_candidate;
    alter table public.applications enable trigger audit;
  end if;

  if not exists (select 1 from public.applications where sub_status_key = v_from.key)
     and not exists (select 1 from public.application_events
                      where from_sub_status_key = v_from.key or to_sub_status_key = v_from.key) then
    delete from public.application_sub_statuses where key = v_from.key;
    v_outcome := 'deleted';
  else
    update public.application_sub_statuses set archived_at = coalesce(archived_at, now()) where key = v_from.key;
    v_outcome := 'retired';
  end if;

  insert into public.activity_log (actor_person_id, actor_user_id, entity_type, entity_id, action, before, after)
  values (v_me, auth.uid(), 'application_sub_statuses', v_from.key,
          case v_outcome when 'deleted' then 'DELETE' else 'UPDATE' end,
          jsonb_build_object('key', v_from.key, 'stage_key', v_from.stage_key, 'label', v_from.label,
                             'archived_at', v_from.archived_at),
          jsonb_build_object('outcome', v_outcome, 'moved', v_n, 'moved_to', v_to_key, 'moved_to_label', v_to_label));

  return jsonb_build_object('moved', v_n, 'outcome', v_outcome);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.sub_status_usage(text), public.remove_sub_status(text, text) from public, anon;
grant execute on function public.sub_status_usage(text), public.remove_sub_status(text, text) to authenticated;

commit;
