# Plan 036: Leave UI

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: L / **Risk**: LOW (no migration; every write
  goes through 0027's functions) / **Depends on**: 035 (`de743cd`)
- **Category**: feature. Layout agreed with the maintainer: a Leave nav item
  (Calendar · Requests · Balances · Holidays), My leave on My workspace, a
  Leave tab on the company profile, a Leave card on the person profile,
  Home queue rows.

## Scope

- `lib/leave.ts`: `workingDaysBetween` (mirror of `app.working_days` for
  the form preview), `leaveInput`, `leaveActions` (approve / reject /
  cancel / ask — the same rules as `decide_leave`, `cancel_leave`,
  `request_leave_cancellation`), `cancellationState`, `monthGrid`.
  `lib/holidayImport.ts` ported verbatim from Field Notebook with its
  tests; `expandForImport` emits `observed_of` for substitute days.
  `lib/homeQueue.leaveToRows`: pending requests and open cancellation asks
  for leave.approve holders, never one's own.
- `lib/companyForm`: `country_code`, `leave_entitlement_days`,
  `leave_carry_over_until` on the company form (a company without a
  country cannot receive leave requests — the form says so).
- Components: `LeaveRequestDialog` (self or on behalf, working-day preview
  from the person's calendar, "record as approved" for approvers),
  `LeaveRequestsList` (rows + actions, prompts for reasons),
  `LeaveCard` (balance rails per current employment + own requests; used
  on My workspace and the person profile), `leave/LeaveCalendarPanel`
  (month grid over `team_leave` — redaction stays server-side; holidays and
  closures shaded; no entry on non-working days), `leave/LeaveRequestsPanel`
  (waiting / recent), `leave/LeaveBalancesPanel` (everyone employed, per
  year; entitlement + adjust with reasons; "set default for N without a
  balance"), `leave/HolidaysPanel` (statutory per country: add, remove,
  paste the official programme, roll last year forward; closures per
  company).
- `LeavePage` at `/leave?tab=&company=`: companies = employed in, or a
  leave grant, or admin; Requests tab only for approvers, Balances only with
  leave.view. Company profile Leave tab (calendar + link). Home queue rows.

## Verification

- Unit: `leave.test.ts` (5), `holidayImport.test.ts` (19),
  `homeQueue.test.ts` (+1), `companyForm.test.ts` (+2).
- E2E `leave.spec.ts`: paste import → entitlement → employee request with the
  holiday excluded (4 of 5 days) → Home queue row → Requests tab approve →
  balance moved → calendar entry (none on the holiday) → employee cancels
  before the start → balance restored.
