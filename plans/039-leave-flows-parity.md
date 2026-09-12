# Plan 039: Leave flows — parity with Field Notebook

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: M / **Risk**: LOW-MEDIUM (one storage policy)
  / **Depends on**: 036, 037 data in place
- **Category**: feature. Requested by the maintainer while testing on the
  migrated data: "check how HT has this implemented and bring it here".

## What Field Notebook had that 036 did not

1. **Day rail** — click a calendar day: what the day is (working / weekend /
   holiday / closure), "N people away", each with type (or "Away"), dates,
   "day 2 of 5", note, a link to the record when the viewer may open it.
   Same component everywhere (Leave → Calendar, company Leave tab).
2. **Request preview** — the balance *after* the request ("14 of 22 days
   left") and a same-department clash warning (pending counted; a heads-up,
   never a block). The number comes from `public.requestable_leave(person,
   company, start, end)` (migration 0029) — the same arithmetic
   `request_leave` uses (pending held aside, carry-over by window), so the
   form never disagrees with a refusal.
3. **Certificates** — a sick-leave request with none attached opens the
   person's self-upload window for `medical_certificate` (0029:
   `has_open_document_request` and a dedicated storage insert policy — the
   0021 delete window stays tied to HR document requests). The row shows
   "certificate to follow / missing / the file", with "Add certificate" for
   the person (until one is attached) and for HR with documents.upload.
   Approvers without documents.view still see that one was provided.
4. **Emails** — `POST /api/leave/notify {requestId, event}`: approvers
   (the company's HR contact, else everyone with leave.approve) hear about a
   new request or an ask to cancel; the person hears the decision with what
   is left. The service checks the caller may speak for the request, that
   the event matches the record's state, throttles repeats (10 min per
   request and event), and reports emailSent=false instead of failing —
   nothing is sent until RESEND_API_KEY / EMAIL_FROM exist.

Not carried over: "erase an approved record" (Personnel cancels with a
reason and keeps history).

## Verification

- Unit: `leave.test.ts` (dayKind, leaveProgress, balanceAfter, clashesWith),
  server `leaveEmails.test.ts` (builders, recipients, event check,
  throttle).
- Smoke: certificate window opens for the pending sick request, not for
  other categories; storage insert window open, delete window closed;
  closes once attached; `requestable_leave` matches `leave_balance` and is
  gated by leave.view.
- E2E `leave.spec.ts`: balance preview, day rail (person + note; holiday
  shows the name and nobody away), sick request → certificate attached from
  the row → linked in the database.
