-- 0083_promotions_follow_their_job.sql
-- A promotion belongs to its job, and should leave with it (plan 064).
--
-- The maintainer, having cleared a job's applicants: "the delete button is
-- still gray… i need to be able to delete this". Two reasons, and this is the
-- second.
--
-- The first was that the applicant was still there (its offer and interview
-- made it undeletable until 0082). Behind it sat this: `promotions.job_id` is
-- NO ACTION, the Frontend Dev job carries one promotion, and nothing anywhere
-- in the app deletes a promotion. So the Delete job button would have gone
-- from disabled straight to a raw foreign-key error — and the count it shows
-- only ever looked at applications, which is my own oversight from an hour
-- ago.
--
-- A promotion is the marketing brief for one job: the public blurb, the copy,
-- where it was posted. It has no meaning without the job, and `job_channels`
-- — the other per-job publishing record — has cascaded since 0003. So this is
-- the odd one out rather than a deliberate guard, and it follows its job now.
--
-- What does NOT cascade with it: the creative document, which lives in
-- `documents` and belongs to the company, and the applications, which are
-- still NO ACTION because a person who applied is not a publishing artefact.
alter table public.promotions
  drop constraint promotions_job_id_fkey,
  add constraint promotions_job_id_fkey
    foreign key (job_id) references public.jobs(id) on delete cascade;
