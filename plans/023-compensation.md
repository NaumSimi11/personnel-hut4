# Plan 023: Compensation

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: MEDIUM (sensitive data) / **Depends on**: main (post-022, `6b5df6e`)
- **Category**: feature (core plan §2 "Change compensation: separate
  restricted action with currency and pay basis; preserve previous amount
  and date; prevent ambiguous overlapping changes"; blueprint §3 salary
  visibility never implied by a title)

## Migration 0017

- `compensation_records` becomes a state machine driven by two functions;
  the direct write policy is replaced by RPC-only writes (reads unchanged:
  self or `salary.view`).
- `propose_compensation(p_period_id, p_amount, p_currency, p_pay_basis_key,
  p_effective_date, p_note)`: `salary.propose`; amount > 0; ISO currency;
  effective date ≥ period start and later than the current approved record's
  effective date; one open proposal per period.
- `decide_compensation(p_record_id, p_decision, p_note)`: `salary.approve`,
  approver ≠ proposer; approving closes the currently approved record the
  day before the new effective date (it stays `approved`; "superseded" is
  read from the dates — migration 0020) so the exclusion constraint never
  fires; rejecting records the decision.
- `compensation_summary(p_company_id)`: `payroll.summary`; headcount with an
  approved record, totals annualised by currency (monthly ×12, daily ×260,
  hourly ×2080 — the standard working-year assumptions, stated in the UI),
  people without a record.

## App

- Person profile: **Compensation** card — current approved amount (with
  basis, since), pending proposal (Approve / Reject for approvers who did
  not propose it), Propose change form (`salary.propose`), history.
  Rendered only when the viewer can see it (self or `salary.view`).
- My workspace: own current compensation and history.
- Company profile: **Payroll** tab (`payroll.summary` holders) — annualised
  totals by currency, headcount covered / not covered.
- `lib/compensation.ts`: form schema, annualisation, formatting, action
  mirror.

Tests: smoke (propose → self-approval refused → approve by another
supersedes → history intact → gating), unit, E2E `compensation.spec.ts`.

Out: payroll periods / export (later slice), bonuses and allowances beyond
one amount per record.
