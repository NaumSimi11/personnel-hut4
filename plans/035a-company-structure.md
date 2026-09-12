# Plan 035a: Company structure — the holding employs, transfers, closing a company

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 (blocks the leave migration) / **Effort**: S / **Risk**: LOW / **Depends on**: main (post-034, `9d5bfe3`)
- **Category**: feature (the real structure: Hut4 Capital is the holding
  *and* employs 18 people; Synami, Liquiditas, Praedium, Snowball beneath
  it; Liquiditas may close, with its people transferred first)

## Migration 0026

- **The holding is an employer.** No schema change — `employment_periods`
  never restricted the company's kind; only the app's pickers did.
- `transfer_employment(p_period_id, p_company_id, p_effective_date,
  p_job_title, p_employment_type_key, p_reason)` (`employment.edit` in
  both companies): the current period ends the day before (end date and
  last working day) and a new one starts on the date at the target company
  — same title and type unless given. Dated today or earlier the old
  period becomes `former` and the new one `active` at once; dated later
  the new one is `pre_start` and the old keeps working until the day, when
  the nightly job (`apply_due_employment_changes`) completes it. The link
  is explicit (`employment_periods.transferred_to_period_id`) so a
  transfer is never mistaken for a departure: no offboarding plan, no
  equipment return tasks. Pending scheduled changes on the old period are
  cancelled (the departure trigger already does this once it is former).
- `archive_company(p_company_id)` (platform admin): refuses while anyone
  is still employed there, naming how many; a trigger guards the direct
  update the same way. The holding is never archived.

## App

- Every company picker (add person, request hire, access editor,
  directory, profile, reports, home count) lists every live company, the
  holding included; the Companies page shows the holding's headcount.
- **Transfer** dialog (target company, date, title, type, reason) on the
  person profile's employment row and on the company People tab.
- Archive on the company Overview goes through the function; a refusal
  lists the people still employed with a Transfer button each.

Tests: smoke (both-company capability, archived target refused, date
rules, immediate vs future statuses, link, nightly completion, archive
guard and trigger), E2E `transfer.spec.ts` (employ at the holding →
transfer to Synami → archive a closing company refused → transfer →
archived).
