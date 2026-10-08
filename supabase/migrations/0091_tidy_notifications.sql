-- 0091_tidy_notifications.sql
-- Tidying my notifications (plan 071). Every action anybody takes on a
-- request, a task, a candidate or a handover leaves a row for someone, and
-- HR's inbox only grows: the page shows the last hundred of thousands. Each
-- person may now archive their own (hidden, kept, restorable) and delete
-- them for good — picked ones, or everything already read, or everything
-- archived, however many there are.
--
-- Own rows only, as everywhere in this table (RLS reads app.is_self; the
-- client never writes it). The bulk forms never sweep up an unread row: an
-- unread one goes only when somebody picked it by hand. Deleting a row whose
-- email is still pending cancels that email — the sender reads the table.

begin;

alter table public.notifications add column archived_at timestamptz;
create index notifications_live_idx on public.notifications (person_id, created_at desc) where archived_at is null;
create index notifications_archived_idx on public.notifications (person_id, archived_at desc) where archived_at is not null;

-- --------------------------------------------------------------- archive
-- p_ids: those of mine; null: every notification of mine already read and
-- not yet archived. Archiving reads it.
create or replace function public.archive_notifications(p_ids uuid[] default null) returns int
language plpgsql security definer set search_path = public as $$
declare v_me uuid := app.current_person_id(); v_n int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_ids is not null and coalesce(array_length(p_ids, 1), 0) = 0 then
    raise exception 'Pick at least one notification.' using errcode = '22023';
  end if;
  update public.notifications
     set archived_at = now(), read_at = coalesce(read_at, now())
   where person_id = v_me and archived_at is null
     and (case when p_ids is null then read_at is not null else id = any(p_ids) end);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- --------------------------------------------------------------- restore
create or replace function public.restore_notifications(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare v_me uuid := app.current_person_id(); v_n int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 then
    raise exception 'Pick at least one notification.' using errcode = '22023';
  end if;
  update public.notifications set archived_at = null
   where person_id = v_me and archived_at is not null and id = any(p_ids);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------- delete
-- p_ids: those of mine. Or, with no ids, p_where says which heap:
-- 'read' (read and not archived) or 'archived'. Nothing else is accepted, so
-- a call with neither deletes nothing rather than everything.
create or replace function public.delete_notifications(p_ids uuid[] default null, p_where text default null) returns int
language plpgsql security definer set search_path = public as $$
declare v_me uuid := app.current_person_id(); v_n int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_ids is not null then
    if coalesce(array_length(p_ids, 1), 0) = 0 then
      raise exception 'Pick at least one notification.' using errcode = '22023';
    end if;
    delete from public.notifications where person_id = v_me and id = any(p_ids);
  elsif p_where = 'read' then
    delete from public.notifications where person_id = v_me and archived_at is null and read_at is not null;
  elsif p_where = 'archived' then
    delete from public.notifications where person_id = v_me and archived_at is not null;
  else
    raise exception 'Say which notifications to delete.' using errcode = '22023';
  end if;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.archive_notifications(uuid[]), public.restore_notifications(uuid[]),
  public.delete_notifications(uuid[], text) from public, anon;
grant execute on function public.archive_notifications(uuid[]), public.restore_notifications(uuid[]),
  public.delete_notifications(uuid[], text) to authenticated;

commit;
