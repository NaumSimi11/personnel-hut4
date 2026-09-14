# Plan 043: Notifications on both sides

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: L / **Risk**: MEDIUM (replaces three ad-hoc
  mailers) / **Depends on**: 039, 042
- **Category**: platform. After Field Notebook's model — an HR recipient per
  company, the person's own address for what concerns them, every action
  saying whether the mail went — generalised: one layer on top of every
  module, both sides.

## Migration 0034

- `notifications`: one row per recipient and event (title, body, link into
  the app, entity, `dedupe_key` = event + recipient, `email_to`,
  `email_status` pending / sent / failed / skipped with error and attempts,
  `read_at`). RLS: a person reads their own; `mark_notifications_read(ids)`
  is the only write from the client.
- `companies.hr_notification_email`: the HR inbox for the company; empty =
  each approver's own work email.
- `app.notify(...)` decides the address (HR inbox for HR-side events,
  otherwise the recipient's work email; none → in-app only, mail skipped)
  and deduplicates. `app.approvers_or_contacts(company, cap)`: grant holders
  of the capability, else the HR contact / director. Admins are not
  spammed — they act through grants like anyone else.
- Triggers create the rows: leave (requested → approvers; decided,
  cancelled by HR, cancel declined, corrected → the person; ask to cancel →
  approvers), hiring requests (submitted / resubmitted → approvers,
  assigned → manager; decided → requester; approved → manager "recruitment
  can proceed"), candidate handed to an owner, document requests (asked →
  person; submitted → reviewer; accepted / needs correction → person).
  Resubmitting a hiring request clears its old `change_reason` (0033).

## Service

- `POST /api/notifications/deliver` replaces `/api/leave/notify`,
  `/api/hiring/notify-assignment` and `/api/hiring/notify-manager`: sends
  queued mails (Resend, idempotency key per row), records sent / failed
  (retried up to five times) / skipped per row; when delivery is not
  configured the rows wait and the app says so. Any signed-in person may
  kick it; the app does after actions.

## App

- Bell in the sidebar with the unread count (polled every minute), the
  Notifications page (unread with a green bar, earlier folded away, each
  row opens where the thing is and marks itself read, the email state on
  each row), "Mark all read".
- Company Settings: "HR inbox for this company".
- Notices after actions say what happened to the mail:
  "Notified: 2 emails sent, 1 without an address." / "Notified in the app.
  Email delivery is not configured yet, so nothing was sent."

## Verification

- Smoke: request → approver row to the HR inbox with the right text and
  link; the person sees none of it; decision → the person at their own
  address with note and decider; mark read; two approvers → one row each,
  repeats ignored; cancel ask and decline; hiring assigned / go / decided;
  no address → skipped, row kept.
- Unit: `renderNotificationEmail`, `deliverySentence` callers typecheck.
- E2E `leave.spec.ts`: HR's bell counts the request, opening it lands on
  the Requests tab; the employee sees "approved" and "corrected" under
  their bell and marks all read. Hiring, candidate, document and
  company-ops specs pass with the new notices and clean their rows up.
