# 064 — Clearing a job (migrations 0082 + 0083)

The maintainer, in a testing phase, trying to get rid of one job:
*"i dont know why ui cant delete ivana at this point, she is onyl an
applicant"* … *"i delete all the job aplicants — the delete button is still
gray. what do we do now?"*

## Two dead ends of our own making

**One.** `delete_job_application` (0081) refuses an application with files,
interviews or offers and says *"remove those records before deleting"*.
Nothing in this app removes an offer or an interview. So that refusal had no
way out: the leftover test application on live carried one of each and could
never have been deleted by anybody.

**Two.** With the applicant finally gone, the job still would not go, because
`promotions.job_id` was NO ACTION and nothing in the app deletes a promotion
either. The Delete job button would have moved from disabled straight to a raw
foreign-key error — and its count only ever looked at applications, which was
this session's own oversight an hour earlier.

Both had the same shape: a rule that forbids something with no way to satisfy
it. A refusal you cannot act on is not a rule, it is a wall.

## What changed

**0082 — say it twice.** `delete_job_application` takes `p_force`. Off, it
behaves exactly as 0081 did: an interview is somebody's written opinion of a
person and an offer is a number that was sent, and neither should vanish
because a list looked untidy. On, it takes them and reports how many of each,
so the confirmation can name the price *before* the call — "also has 1 file, 1
interview and 1 offer, and they go with it" — and hand back the storage paths,
which SQL cannot reach. The one-argument form is dropped rather than left
beside the new one: 0043 already learned that an overload makes the call
ambiguous from PostgREST.

**0083 — a promotion follows its job.** It is the marketing brief for one job:
the blurb, the copy, where it was posted. It means nothing without the job, and
`job_channels` — the other per-job publishing record — has cascaded since 0003.
So this was the odd one out rather than a guard. Applications stay NO ACTION:
a person who applied is not a publishing artefact.

**Delete job** is back on the job page (lost earlier to a concurrent rewrite of
that file), disabled while applications remain, with the count and where to
clear them in its title.

## Verified against live, not just locally

Signed in as the maintainer and ran both calls through PostgREST as him:

- `delete_job_application(force)` on the leftover row → `{files: 1,
  interviews: 1, offers: 1, deleted: true}` with the storage path returned.
- `DELETE /jobs?id=eq.…` on Frontend Dev → 200, and its promotion went with it.
- The hiring request behind it now reports **0 jobs from it**, so it is
  deletable from the Requests tab.
- The orphaned storage object was removed by hand, since a raw API call does
  not run the app's cleanup.
