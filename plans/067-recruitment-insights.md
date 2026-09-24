# 067 — Recruitment insights (what we took from the Zoho Recruit home)

Status: implemented, migration 0086 not yet applied to the live database.

## Why

The Zoho Recruit home showed hiring laid out per job and measured in time —
how long openings stay open, how long hires take, how many offers land. The
PeopleOS Home had one pipeline across every job and Reports had counts only.
Everything needed was already recorded (stage-change events with dates and
actors, Zoho's own created and hired dates on the import, offers with their
outcome, interviews with a time); only a job's opening date was missing.

## What changed

**Database — `0086_recruitment_insights.sql`**
- `jobs.opened_at`: the first time a job went live. Backfilled from the
  audit trail (Zoho jobs: their Zoho creation date), stamped by
  `t3_opening_stamp` on the way into `open`, and immutable once set.
- `recruitment_insights(company, from, to)`: time to fill per opening (to
  the hire that completed its headcount, or today while short; only hires
  made after the job opened count; an opening whose headcount is met shows
  only when that hire falls in the range; days past the hiring request's
  target start), time to hire per hire, offers by
  outcome, and the latest 60 stage changes. `jobs.view` to call it;
  candidate names only with `candidates.view`.
- The whole migration runs in one transaction.
- Smoke block `0086` in `supabase/tests/smoke.sql`.

**Home** (`components/home/`)
- `HiringBoard.vue` — one row per live job with applicants: a count per
  stage (rejected + withdrawn together as Closed), the furthest stage drawn
  as an arrow, how long the job has been open, a company picker when more
  than one company shows, eight rows then "Show all". A row opens the job's
  Applications tab.
- Open positions: "open N days", oldest first, amber past 90 days.
- `UpcomingInterviews.vue` — scheduled interviews in the next seven days.

**Reports** (`components/reports/RecruitmentTiming.vue`)
- Tiles: average days to fill, average days open, average days applied →
  hired, offer acceptance, open roles past target start.
- Time to fill and Time to hire tables; Recent activity feed.

Pure shaping lives in `lib/hiringBoard.ts` and `lib/insights.ts`, with unit
tests; `e2e/home-dashboard.spec.ts` and `e2e/reports.spec.ts` cover the new
widgets.

## Deliberately not taken

Per-widget user/time filters (one filter per page is enough), "My unattended
calls" (no call tracking), "My actions" (the Home queue already does it),
truncated job titles, empty-job rows, promotional banners.

## Rollout order

Apply 0086 **before** deploying the frontend: Home selects `jobs.opened_at`
and Reports calls `recruitment_insights`; without the migration Home cannot
load its jobs.
