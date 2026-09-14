-- 0030_admin_self_approval.sql
-- Hiring requests: a platform admin may decide their own request. In a
-- holding this size the owner both raises and approves hires; the four-eyes
-- rule stays for everyone else (blueprint §3 default). decided_by is still
-- server-set, so the trail shows who did it.

create or replace function app.gate_hiring_request_transitions() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' then prev := old.status; end if;
  if new.status in ('approved','rejected') and new.status is distinct from prev then
    if not app.has_capability(new.company_id, 'jobs.approve') then
      raise exception 'Deciding a hiring request requires jobs.approve'
        using errcode = '42501';
    end if;
    if new.requested_by is not distinct from app.current_person_id() and not app.is_admin() then
      raise exception 'Requesters cannot decide their own hiring request'
        using errcode = '42501';
    end if;
    new.decided_by := app.current_person_id();
    new.decided_at := now();
  end if;
  return new;
end $$;
