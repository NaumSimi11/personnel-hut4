# Plan 035: Leave — schema and rules (ported from Field Notebook)

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 (leave moves into Personnel) / **Effort**: L / **Risk**: MEDIUM (balances) / **Depends on**: main (post-035a, `9e6fb3c`)
- **Category**: feature. Source of the rules: `E:\ht-hpt` (Field Notebook)
  — `leaveUtils.workingDaysBetween`, `balancePolicy` (carry-over drawn by
  the requested dates, never by today), `shared/leaveStatus`,
  `shared/leaveCancellation`, `shared/leaveVisibility`,
  `shared/leaveDocumentState`. Two of its defects are fixed on the way in:
  pending requests count against what can be requested and approval
  re-checks under a row lock; the yearly rollover is a scheduled job.

## Migration 0027

- **Types** `leave_types` (key, label, deducts_balance, requires_document,
  is_active, sort_order): annual, sick, unpaid, justified_day, other.
- **Calendars**: `public_holidays` (country_code, date, name, kind
  statutory|other, observed_of) unique per country and date — one list per
  country; `company_closures` (company_id, date, name) — a closure applies
  to that company only (Field Notebook's known gap). `companies.country_code`
  and `locations.country_code` decide a person's calendar: the employment's
  location first, then the company. `app.working_days(start, end, country,
  company)` excludes weekends, that country's holidays and that company's
  closures.
- **Balances** per person, company and year: `leave_balances`
  (entitlement_days, carry_over_days, carry_over_expires_on) plus
  `leave_adjustments` (signed days, kind, reason, who). Everything else is
  derived: used = approved deducting requests of the year; carry-over is
  drawn first, only for working days inside its window (Jan 1 → expiry);
  after expiry what is left of it is gone. `leave_balance(person, company,
  year)` returns the whole picture; `requestable_leave(...)` subtracts
  pending requests too. Company defaults: `leave_entitlement_days` (22),
  `leave_carry_over_until` ('06-30'). `roll_leave_year(year)` (idempotent,
  nightly job on 1 January): next year's row per current employment,
  carry-over = what was left.
- **Requests** `leave_requests`: person, employment, company (derived),
  type (+ snapshotted `deducts_balance` / `requires_document`), dates,
  working_days (snapshot), carry_over_days_used, note, status
  pending|approved|rejected|cancelled, documents_to_follow, decision and
  cancellation facts, `legacy_id` for the import. Documents are
  `documents` rows (category `medical_certificate`, person_and_hr) linked
  through `leave_request_documents`.
- **Functions** (SECURITY DEFINER, capability-checked): `request_leave`
  (self, or `leave.approve` on behalf — never self-approving; annual leave
  within one year; ≥ 1 working day; sick leave needs a document or the
  promise of one; `recordAsApproved` for approvers), `decide_leave`
  (`leave.approve`, not for oneself), `cancel_leave` (owner before the
  start or an approver at any time; reason required), `request_leave_
  cancellation` / `decline_leave_cancellation`, `attach_leave_document`,
  `adjust_leave_balance` (`leave.adjust`), `set_leave_entitlement`,
  `team_leave(company, from, to)` — colleagues' rows redacted to "Away"
  server-side unless the viewer is the person or holds `leave.view`.
- **Capabilities** `leave.view`, `leave.approve`, `leave.adjust`,
  `holidays.manage` (+ presets). RLS: requests readable by the person and
  by `leave.view`/`leave.approve` in the company; no direct writes.

Tests: smoke (working days with holidays and closures, balance math incl.
carry-over window and expiry, pending counted, approval lock, self-cancel
before/after start, redaction, gates, rollover idempotence).

App work is plan 036.
