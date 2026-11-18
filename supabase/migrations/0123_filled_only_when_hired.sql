-- 0123: a job is Filled only when every position is hired (board card B7).
--
-- The job status was a free dropdown, so an open job with no hires could be
-- set straight to Filled. Filled now means what 0090 made it mean: the hires
-- reached the headcount. The last hire still fills the job itself (0090),
-- and that write passes this check because the count is met.
--
-- Only a person in the app is held to it (role authenticated): the Zoho
-- import and admin scripts keep writing the status a source system had.

begin;

create or replace function app.job_filled_needs_hires() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_open int;
begin
  if new.status = 'filled' and old.status is distinct from 'filled'
     and current_setting('role', true) = 'authenticated' then
    v_open := app.job_headcount(new.id)
            - (select count(*) from public.applications a where a.job_id = new.id and a.stage_key = 'hired');
    if v_open > 0 then
      raise exception 'This job still has % open position%. It fills itself when the last one is hired.',
        v_open, case when v_open = 1 then '' else 's' end
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists t2_filled_needs_hires on public.jobs;
create trigger t2_filled_needs_hires before update of status on public.jobs
  for each row execute function app.job_filled_needs_hires();

revoke all on function app.job_filled_needs_hires() from public;

commit;
