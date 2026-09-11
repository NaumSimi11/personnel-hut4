# Plan 022: Employment changes, structure, directory filters

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: L / **Risk**: MEDIUM / **Depends on**: main (post-021, `d7e47cc`)
- **Category**: feature (core plan §2 "Change job/manager/location: capture
  new values, effective date, reason; future change does not overwrite
  today's record; prevent circular reporting relationships"; departments /
  locations management; directory saved filters)

## Migration 0016

- `employment_changes` (employment_period_id, company_id derived,
  effective_date, changes jsonb — any of job_title, department_id,
  location_id, manager_id, employment_type_key — reason, status
  scheduled|applied|cancelled, created_by, applied_at). RLS: read
  `people.view` in the company; write via RPC only (cancel by
  `employment.edit`). Audited.
- `public.schedule_employment_change(p_period_id, p_effective_date,
  p_changes, p_reason)`: requires `employment.edit`; effective date ≥ the
  period's start; department/location must belong to the company or be
  shared; manager may not be the person and may not (transitively) report to
  them — `app.would_create_cycle`; a change effective today or earlier is
  applied immediately, otherwise scheduled. Returns `{ change_id, applied }`.
- `public.apply_due_employment_changes()`: applies every scheduled change
  whose date has arrived; idempotent; called by the app on directory and
  profile load (and safe from a cron later).
- `public.cancel_employment_change(p_change_id)`: `employment.edit`,
  scheduled only.

## App

- Person profile: employment row shows department, location, manager; a
  **Schedule change** dialog (effective date, job title, department,
  location, manager, employment type, reason); pending changes listed with
  Cancel; header shows the manager.
- Company profile: **Structure** tab — departments and locations (add,
  rename, archive; admins), shared rows marked.
- Directory: filter chips (Active · Starting soon · Departing · Former · No
  employment) and a company filter; the "current" period is the
  non-former one, else the latest.

## Tests

Smoke: immediate vs scheduled application, cycle refusal, foreign department
refusal, cross-company refusal, cancel. Unit: `lib/employmentChanges.ts`
(schema, diff builder, labels), directory predicate. E2E
`employment-changes.spec.ts`.

Out: rehire flow, import preview, compensation (own slice).
