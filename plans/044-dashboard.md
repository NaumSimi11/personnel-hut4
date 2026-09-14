# Plan 044: Dashboard by role, and the Recruitment tabs

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: M / **Risk**: LOW (reads; one small table)
  / **Depends on**: 043
- **Category**: product. The prototype on `origin/hut4-hr-build`
  (`hr-system.html`, served at personnel-hut4.vercel.app) showed the
  stakeholders a Home they liked: headline numbers by role, the applicant
  pipeline, open positions and recent applicants, and a "Celebrate" block
  (kudos, birthdays, work anniversaries, new teammates, a fun corner). Our
  Overview had four counts and the decision queue. This plan brings the
  prototype's Home onto real data, gated by capabilities instead of the
  prototype's four fixed roles, and adds the two Recruitment tabs the
  prototype had and we lacked.

## What the prototype shows, and what we do

| Prototype (role) | Personnel | Gate |
| --- | --- | --- |
| Active employees / Total headcount (all roles) | People employed in the viewer's companies (active; pre-start counted separately) | `app.in_company` |
| Applicants in progress (admin, HR) | Applications not hired / rejected / withdrawn | `jobs.view` anywhere (RLS) |
| Last payroll (net) (admin, finance) | Latest approved or exported payroll period per company: prepared total | `payroll.summary` per company (in the RPC) |
| Applicant pipeline bars (admin, HR) | Counts per stage across visible applications | `jobs.view` anywhere |
| Open positions / Recent applicants (admin, HR) | Open jobs with their applicant count; five newest applications | `jobs.view` anywhere |
| Give kudos / Kudos wall (all) | `kudos` table; the wall shows kudos to colleagues | colleague = shares a company |
| Birthdays next 30 days (all) | Colleagues' birthdays, **day and month only** — the year never leaves the database | `app.in_company` |
| Work anniversaries next 30 days (all) | From the current employment's start date | `app.in_company` |
| New teammates last 30 days (all) | Employment started in the window | `app.in_company` |
| Fun corner (all) | Most kudos, biggest team, anniversaries this year, "Surprise me" shoutout | — |
| — | Away today (approved leave covering today, what the viewer may see) | leave RLS |
| — (kept from Overview) | Needs a decision queue, My tasks | as before |

Recruitment tabs (prototype: Job openings, Applicants):

| Prototype | Personnel before | After |
| --- | --- | --- |
| Job openings: title, department, headcount, status, applicant count | Jobs reachable only through "Open job" on an approved request | **Job openings** tab on Hiring: every job the viewer may see, status, headcount, applicants, open it |
| Applicants: flat list, stage, applied date, position; add applicant | Per job only (Applications tab) | **Applicants** tab on Hiring: every application across jobs, stage filter, search, open the candidate or the job |
| Add applicant (name, email, phone, position, stage, date) | Add candidate + Upload CVs per job | unchanged — adding is per job (a candidate always belongs to a job) |

## Migration 0035

- `app.is_colleague(p)`: the viewer shares a company with `p` (an employment
  that counts as employed in a company where `app.in_company`), or is `p`.
- `app.days_until_next(date)`: days from today to the next yearly occurrence
  (29 Feb → 28 Feb in common years).
- `kudos` (from, to, message 1–280, created_at). RLS: read where the receiver
  is a colleague or I gave it; insert only as myself to a colleague, never to
  myself; delete my own (admins any). Audited.
- `dashboard_snapshot(p_days default 30, 1–90)` → jsonb, one call:
  `headcount`, `active`, `starting` (pre-start), `colleagues` (id, name,
  company — the kudos "To" list), `birthdays` (name, title, company, on_day
  "DD Mon", in_days), `anniversaries` (years, in_days), `newcomers`
  (start_date), `kudos` (last 30, with names, `mine`), `top_kudos`,
  `biggest_team`, `anniversaries_this_year`, `payroll` (latest approved /
  exported period per company where the viewer holds `payroll.summary`).
  The team is scoped by `app.in_company`; admins see the holding.

## App

- `stores/auth.ts`: `canAnywhere(cap)` — the gate for holding-wide panels.
- `lib/dashboard.ts` (pure, unit-tested): `pipelineCounts`, `openPositions`,
  `recentApplicants`, `awayToday`, `inDaysLabel`, `shoutoutLine`,
  `applicantsInProgress`, `payrollLabel`.
- `components/home/`: `DashboardStats.vue`, `RecruitmentSnapshot.vue`
  (bars + open positions + recent applicants), `CelebratePanel.vue` (kudos
  form + wall, birthdays, anniversaries, new teammates, fun corner),
  `AwayToday.vue`. `HomePage.vue` composes them around the queue.
- `pages/HiringRequestsPage.vue`: tabs Requests · Job openings · Applicants
  (`?tab=`); `components/hiring/JobOpeningsPanel.vue`,
  `components/hiring/ApplicantsPanel.vue`.

## Tests

- smoke: Omar (no grants) sees colleagues from A only, Fiona's birthday
  without a year, the anniversary and the newcomer fixtures, no payroll;
  Fiona sees the payroll of A; kudos to a colleague lands with names, to
  someone in another company is refused, to oneself is refused; the giver
  removes it, another cannot.
- unit: `lib/dashboard.test.ts`.
- E2E `home-dashboard.spec.ts`: the admin's Home shows the pipeline and the
  celebrate block; give kudos → on the wall → remove. Hiring tabs: Job
  openings lists a job, Applicants lists an application and filters by stage.
