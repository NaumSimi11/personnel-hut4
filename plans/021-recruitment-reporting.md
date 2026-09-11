# Plan 021: Recruitment reporting

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P2 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-019, `602e047`)
- **Category**: feature (blueprint §8 "source reports connect applications
  to interviews and hires where tracking data supports attribution; unknown
  sources remain unknown"; core plan §1 dashboard from real records)

## Design

One SECURITY DEFINER report function does the counting in the database, so
the page never pulls candidate rows to the browser and the numbers are the
same for everyone who may see them:

`public.recruitment_report(p_company_id uuid, p_from date, p_to date) → jsonb`
- Requires `jobs.view` in the company (counts only, no candidate PII —
  blueprint: candidate counts stay available to recruiting users).
- `kpis`: open_roles, active_candidates (non-terminal applications on open
  jobs), received (applications received in range), hires (hired in range),
  median_days_to_hire, avg_days_to_hire (received_at → the hired stage
  event).
- `funnel`: per job (all statuses, jobs with any application in range or
  currently open): title, status, received, counts per stage, hired.
- `sources`: per source (channel label, "Added by hand" for null): received,
  interviewed (reached interview or beyond), hired.
- `attention`: overdue_next_actions, unassigned (non-terminal applications
  with no owner), stale (no stage change in 14 days) — counts.

App: `/reports` (nav "Reports"), company picker (companies the user holds
`jobs.view` in; admins all), date range (default 90 days), KPI tiles, funnel
table, sources table, attention tiles; CSV export of the funnel. Company
profile Hiring tab links to the report.

Tests: smoke (permission + numbers on seeded data), unit (`lib/reporting.ts`:
median/percent/CSV), E2E (seed applications at stages with one careers-
sourced hire → KPIs, funnel row, sources row, CSV download).

Out: charts library (tables and tiles suffice at this scale), scheduled
emails, cross-company roll-up beyond "all companies" for admins.
