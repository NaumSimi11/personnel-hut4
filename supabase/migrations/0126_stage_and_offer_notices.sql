-- 0126: notices at every stage change and offer step (board card T14).
--
-- The approvals, interviews and the offer's return and answer already sent
-- notices (in the app and by email). Two steps sent none:
--   * a stage change: the application's owner and the job's hiring manager
--     now hear when somebody else moves it to another stage (a status inside
--     the same stage stays quiet, so outreach logging does not flood them);
--   * an approved offer: its author hears it can go to the candidate.
-- Neither fires during a Zoho import (app.bulk_import), like the others.

begin;

create or replace function app.notify_stage_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v record;
  v_me uuid := app.current_person_id();
  v_to uuid;
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if new.stage_key is not distinct from old.stage_key then return new; end if;
  select c.full_name, j.title, j.hiring_manager_id, s.label as stage_label into v
    from public.candidates c
    left join public.jobs j on j.id = new.job_id
    left join public.application_stages s on s.key = new.stage_key
   where c.id = new.candidate_id;
  for v_to in select distinct x from unnest(array[new.owner_id, v.hiring_manager_id]) x
               where x is not null and x is distinct from v_me loop
    perform app.notify(v_to, new.company_id, 'application.stage',
      coalesce(v.full_name, 'A candidate') || ' moved to ' || coalesce(v.stage_label, initcap(new.stage_key)),
      coalesce(v.title, 'Role'),
      '/hiring/applications/' || new.id, 'application', new.id,
      'application.stage:' || new.id || ':' || new.stage_key || ':' || to_char(now(), 'YYYYMMDDHH24MISSUS'));
  end loop;
  return new;
end $$;
drop trigger if exists t9_notify_stage on public.applications;
create trigger t9_notify_stage after update of stage_key on public.applications
  for each row execute function app.notify_stage_change();

create or replace function app.notify_offer_approved() returns trigger
language plpgsql security definer set search_path = public as $$
declare v record;
begin
  if new.status <> 'approved' or old.status = 'approved' then return new; end if;
  if new.created_by is null or new.created_by is not distinct from app.current_person_id() then return new; end if;
  select c.full_name, j.title into v
    from public.applications a
    join public.candidates c on c.id = a.candidate_id
    left join public.jobs j on j.id = a.job_id
   where a.id = new.application_id;
  perform app.notify(new.created_by, new.company_id, 'offer.approved',
    'Offer approved: ' || coalesce(v.full_name, 'candidate'),
    coalesce(v.title, 'Role') || ' · ready to send to the candidate',
    '/hiring/applications/' || new.application_id, 'offer', new.id, 'offer.approved:' || new.id);
  return new;
end $$;
drop trigger if exists t9_notify_approved on public.offers;
create trigger t9_notify_approved after update of status on public.offers
  for each row execute function app.notify_offer_approved();

revoke all on function app.notify_stage_change() from public;
revoke all on function app.notify_offer_approved() from public;

commit;
