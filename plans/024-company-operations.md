# Plan 024: Company operations — upcoming people, workflow owners, invite from Access

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: S / **Risk**: LOW / **Depends on**: main (post-023, `69b67e1`)
- **Category**: feature (development plan "company profile leftovers";
  data-model §0005 "approvals route to a configured owner; a NULL owner
  renders as *Unassigned*, approval is never skipped")

## No migration

`workflow_owners` (0005) already exists with `read_all` + `admin_write` RLS
and the audit trigger; `employment_periods` already carries `end_date` and
`last_working_date`. Notification contacts stay deferred until an email
delivery path exists (RESEND_API_KEY); integration connect/configure stays
deferred until provider credentials exist.

## App

- Company **Overview**: an *Upcoming* card — starters (`pre_start`, soonest
  first) and departures (`active` with an end date, soonest first, showing
  the last working date). Rows link to the person. Empty state when none.
- Company **Settings** tab (platform admins): *Workflow owners* — one row per
  `workflow_roles` entry with a select of people employed in this company
  (non-former) or *Unassigned*; saved per row by upsert on
  `(company_id, role_key)`. Saving Unassigned stores a NULL owner (the row
  stays, so the audit trail shows who cleared it).
- **Hiring requests**: submitted / changes-requested rows show *Awaiting
  {hiring approver}* from the company's `workflow_owners`, or *Awaiting
  approval · no approver configured* — routing is informational; the
  `jobs.approve` + not-the-requester gate is unchanged.
- Company **Access** tab: *Invite person* opens the existing
  `InviteAccessDialog`; a hint explains that grants are set in the access
  editor afterwards.
- `lib/companyOps.ts`: `upcoming(periods, today)`, `awaitingLabel(owner)`;
  unit tests.

Tests: unit; E2E `company-ops.spec.ts` (seed a starter and a departing
person at Praedium → Upcoming lists both; Settings → assign the hiring
approver → persisted; seeded submitted request shows *Awaiting {name}*;
Access → Invite person opens the dialog).

Out: notification contacts, integration connect flows, approval routing
enforcement (a later RPC layer per data-model.md).
