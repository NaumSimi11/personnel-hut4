# Plan 031: Payroll preparation — periods, snapshot lines, approval, export

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: MEDIUM (sensitive data) / **Depends on**: main (post-030, `795f323`)
- **Category**: feature (blueprint §9 "payroll handoff"; data-model
  `payroll_periods` "preparation / export handoff only; currency explicit
  per period"; capabilities `payroll.individual` / `approve` / `export`)

## Migration 0023

- `payroll_periods` gains `prepared_by`; status moves only through
  functions (trigger freezes it and the approval facts).
- `payroll_lines` (new): one line per compensation record in force during
  the period, in the period's currency — person, employment, job title,
  amount, pay basis, effective from / to, `days_covered` (overlap with the
  period). Facts only; pro-rating is the accountant's call. RLS:
  `payroll.individual` in the company.
- `prepare_payroll_period(p_company_id, p_start, p_end, p_currency, p_note)`
  (`payroll.individual`): creates the period (or re-snapshots a draft /
  in-review one for the same range) and its lines → `in_review`; also
  returns how many active people have no approved record in that currency.
- `approve_payroll_period(p_period_id)` (`payroll.approve`, not the
  preparer) → `approved`; `mark_payroll_exported(p_period_id)`
  (`payroll.export`, approved only) → `exported` with `exported_at`;
  `reopen_payroll_period` (`payroll.approve`, approved → in_review).

## App

- `lib/payroll.ts`: period form (month default), status labels, action
  mirror, CSV builder (formula-cell neutralised); unit tests.
- Company **Payroll** tab: below the totals, **Payroll periods** — prepare
  (start / end / currency / note), list with status, line count and total;
  open a period for its lines; Approve (another person), Download CSV +
  Mark exported (`payroll.export`), Re-prepare while in review.

Tests: smoke (snapshot correctness incl. mid-period change and currency
filter, preparer ≠ approver, transitions, RLS), unit, E2E `payroll.spec.ts`
(prepare → lines → self-approval refused → colleague-prepared period
approved → CSV downloaded with the person's line → exported).

Out: storing the export as a document, allowances / one-off items,
pro-rating rules.
