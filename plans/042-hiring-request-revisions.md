# Plan 042: Hiring-request review dialogs, revision flow, hiring-manager notifications

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW-MEDIUM (transition gates
  tightened) / **Depends on**: 030 (admin self-approval)
- **Category**: feature. From the `todo.md` left in the tree on 2026-09-14:
  the two items were built as one slice and the file removed.

## Migration 0033

- `hiring_request_history`: one row per step — submitted, changes
  requested, resubmitted, approved, rejected, cancelled — with the reason,
  a snapshot of the request, the actor and the time; written by trigger so
  nothing is missed. Readable with jobs.view in the company.
- `app.gate_hiring_request_transitions`: sending back (`changes_requested`)
  needs jobs.approve like approve/reject, never on one's own request
  (platform admins excepted), and a reason; resubmitting from "changes
  requested" is the requester's move (or jobs.edit / admin) and clears the
  decision; the content (title, reason, headcount, start date, manager,
  budget) is locked once submitted — only a draft or a request sent back
  may change.

## App

- `DecideHiringRequestDialog`: Request changes / Reject as app dialogs —
  role and company shown, multiline reason required, saving state and
  errors inside, text kept on failure, no double submit. No browser prompts.
- `RequestHireDialog.openRevision`: prefilled with the request sent back,
  the requested changes shown above the form, "Resubmit request" saves to
  the same row and returns it to the queue.
- Requests page: the reason with who asked, **Edit and resubmit** for the
  requester (jobs.edit / admin too), "History (n)" under each request.
- Hiring-manager notifications (`/api/hiring/notify-manager`): on submit or
  resubmit with a manager, "assigned — awaiting approval, not a go-ahead";
  on approval, "recruitment can proceed"; target start named as the
  employee's date, never a deadline. In-app = two Home queue rows for the
  manager, derived from the data (no duplicates, only with jobs.view — the
  assignment grants no access, and the notice says so when it is missing).
  Email once per request, event and manager (provider idempotency key), so
  a retry never doubles; missing address, unconfigured delivery and
  failures come back as a sentence in the page notice.

## Verification

- Smoke: non-approver and requester cannot send back; no reason refused;
  content locked once submitted; approver cannot resubmit someone else's;
  requester revises and resubmits (decision cleared); history in order with
  reason, snapshot and actor.
- Unit: `hiringManagerToRows` (app), `buildManagerEmail` /
  `managerEventMatches` (server).
- E2E `hiring-requests.spec.ts`: request with a manager → notice → Home row
  "awaiting approval" → Request changes dialog (empty refused, cancel keeps
  it) → reason on the row → Edit and resubmit → history (3) → approve →
  notice → Home row "recruitment can proceed".
