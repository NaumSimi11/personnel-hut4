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

The prototype gated its blocks by four fixed roles. We gate by the
capability that already governs that data, so the dashboard can never show
more than the pages it links to. Nobody is shown a zero for something they
may not see — the tile or card is simply absent.

| Prototype (role) | Personnel | Gate |
| --- | --- | --- |
| Active employees / Total headcount (all roles) | People employed in companies whose records the viewer may read (active; pre-start counted separately) | `people.view` |
| Applicants in progress (admin, HR) | Applications not hired / rejected / withdrawn | `candidates.view` |
| Last payroll (net) (admin, finance) | Latest approved or exported payroll period per company: prepared total | `payroll.summary` per company (in the RPC) |
| Applicant pipeline bars (admin, HR) | Counts per stage across visible applications | `candidates.view` |
| Open positions (admin, HR) | Roles being hired with their applicant count | `jobs.view` |
| Recent applicants (admin, HR) | Five newest applications | `candidates.view` |
| Give kudos / Kudos wall (all) | `kudos` table; you thank someone you may see (`app.can_view_person`), and you always read what you gave or received | the directory's own rule |
| Birthdays next 30 days (all) | **Day and month only** — the year never leaves the database | `personal.view` |
| Work anniversaries next 30 days (all) | From the current employment's start date | `people.view` |
| New teammates last 30 days (all) | Employment started in the window | `people.view` |
| Fun corner (all) | Most kudos, biggest team, anniversaries this year, "Surprise me" | `people.view` |
| — | Away today (approved leave covering today) | `leave.view` / `leave.approve` |
| — (kept from Overview) | Needs a decision queue, My tasks | as before |
| — | Hiring requests to decide | `jobs.approve` |

A person with no grants therefore keeps a Home worth opening — their queue,
their tasks, their notifications and the kudos addressed to them — and
learns nothing about colleagues they could not already look up.

Recruitment tabs (prototype: Job openings, Applicants):

| Prototype | Personnel before | After |
| --- | --- | --- |
| Job openings: title, department, headcount, status, applicant count | Jobs reachable only through "Open job" on an approved request | **Job openings** tab on Hiring: every job the viewer may see, status, headcount, applicants, open it |
| Applicants: flat list, stage, applied date, position; add applicant | Per job only (Applications tab) | **Applicants** tab on Hiring: every application across jobs, stage filter, search, open the candidate or the job |
| Add applicant (name, email, phone, position, stage, date) | Add candidate + Upload CVs per job | unchanged — adding is per job (a candidate always belongs to a job) |

## Migration 0035 (and 0036, the limits)

- `app.days_until_next(date)`: days from today to the next yearly occurrence
  (29 Feb → 28 Feb in common years; the anniversary's year minus the start
  year gives the count, which `age()` would round down for such a start).
- `kudos` (from, to, message 1–280, created_at). RLS (0036): read where I may
  see the person thanked (`app.can_view_person`, the directory's rule), or I
  gave or received it; insert only as myself and only to someone I may see,
  never to myself; delete my own (admins any). Audited.
- `dashboard_snapshot(p_days default 30, 1–90)` → jsonb, one call:
  `headcount`, `active`, `starting` (pre-start), `colleagues` (id, name,
  company — the kudos "To" list), `birthdays` (name, title, company, on_day
  "DD Mon", in_days), `anniversaries` (years, in_days), `newcomers`
  (start_date), `kudos` (last 30, with names, `mine`), `top_kudos`,
  `biggest_team`, `anniversaries_this_year`, `payroll` (latest approved /
  exported period per company where the viewer holds `payroll.summary`).
  The team is the people of the companies where the viewer holds
  `people.view`; birthdays need `personal.view` in that company as well;
  payroll has its own company set (`payroll.summary` does not imply
  `people.view`). Admins hold every capability, so they see the holding.
- 0036 replaces 0035's membership-based scoping (`app.is_colleague`, dropped)
  with those capabilities, after the review found the dashboard wider than
  the directory it links to.

## App

- `stores/auth.ts`: `canAnywhere(cap)` — the gate for holding-wide panels.
- `lib/dashboard.ts` (pure, unit-tested): `statTiles` and `dashboardSections`
  (which tile and which block each capability opens), `pipelineCounts`,
  `openPositions`, `recentApplicants`, `awayToday`, `inDaysLabel`,
  `shoutoutLine`, `applicantsInProgress`, `payrollLabel`.
- `components/home/`: `DashboardStats.vue`, `RecruitmentSnapshot.vue`
  (bars + open positions + recent applicants), `CelebratePanel.vue` (kudos
  form + wall, birthdays, anniversaries, new teammates, fun corner),
  `AwayToday.vue`. `HomePage.vue` composes them around the queue.
- `pages/HiringRequestsPage.vue`: tabs Requests · Job openings · Applicants
  (`?tab=`); `components/hiring/JobOpeningsPanel.vue`,
  `components/hiring/ApplicantsPanel.vue`.

## Tests

- smoke: Omar (no grants) gets an empty snapshot and cannot thank someone he
  may not see; Fiona (`people.view` + `payroll.summary`, no `personal.view`)
  gets the team, the anniversary, the newcomer and A's payroll but no
  birthdays, and her kudos carries both names; Omar still reads the kudos he
  received but cannot remove it; Ada (admin) gets the birthday without a
  year; Bea (Company B) sees neither A's people nor kudos between them; the
  giver removes it.
- unit: `lib/dashboard.test.ts` — the gating of every tile and block.
- E2E `home-dashboard.spec.ts`: the admin's Home shows the pipeline and the
  celebrate block; give kudos → on the wall → remove. A plain employee sees
  no tiles, no recruitment, no team cards — only the kudos addressed to them,
  which they cannot remove. Hiring tabs: Job openings lists a job, Applicants
  lists an application and filters by stage.
