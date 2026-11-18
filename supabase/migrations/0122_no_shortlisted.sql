-- 0122: Shortlisted is removed everywhere (board card B2, D2 settled 18 Nov).
--
-- 0105 added "shortlisted" as a Screening status so the board could show a
-- Shortlisted column. The column is gone from the board, and the hiring
-- manager's review is a decision inside Screening ("Your call as hiring
-- manager"). Anything still on Shortlisted moves to Sourced in Screening
-- first, so no application is left on a status that no longer exists
-- (production had none on 18 Nov).

begin;

update public.applications set sub_status_key = 'sourced'
 where sub_status_key = 'shortlisted';

delete from public.application_sub_statuses where key = 'shortlisted';

commit;
