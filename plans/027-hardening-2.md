# Plan 027: Hardening round 2 — insert pinning, payroll continuity, careers robustness

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 (workflow bypass) / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-026, `ec8d034`)
- **Category**: fix (second review round over 012–019)

## Migration 0020

1. **Pinned inserts.** Offers always start `draft` (no approver, not
   accepted); promotions always start `requested` (no copy, no drafter,
   requester = signed-in person). Direct inserts can no longer skip
   `advance_offer` / `advance_promotion`.
2. **Null-safe self-review** in `advance_promotion`.
3. **Payroll continuity.** Approving a future-dated raise no longer flips the
   record in force to `superseded`; it stays `approved` with an end date the
   day before the raise. "Superseded / Current / Scheduled" is read from the
   dates in the app; existing `superseded` rows are converted.
4. **`apply_due_employment_changes`** applies only in companies where the
   caller holds `employment.edit`; a nightly pg_cron job (00:15 UTC) runs it
   as the system so nothing waits for an editor to open a page.
5. **Loop guard on direct manager edits** (`app.guard_employment_manager`).
6. **Redacted audit for `application_files`** (extracted text, file names).
7. **`companies.website` must be a web URL** (check constraint).

## Server (careers)

- IP limit checked before the multipart body is buffered; multipart limit
  errors answer in the `{ error }` contract (413).
- A failed CV upload or file-row insert takes the application back (and the
  object), so the candidate can resubmit instead of hitting the duplicate
  rule with no CV on file.
- Reusing a candidate by email keeps what the form said (name, phone) on the
  timeline note.
- `publicCompany` passes only `http(s)` websites through.

## App

- `todayDb()` — the UTC calendar date, matching Postgres `current_date` on
  the (UTC) Supabase project — used wherever the app reasons about "today".
- RLS zero-row detection on `jobs` writes (open on publish, description
  save); stage-change timeline failures are shown; offer terms render only
  when complete.

Known, accepted for now: linking an application to an existing candidate
by email without verification lets anyone who knows an address block it
for that role until HR withdraws the fake — proper email verification
needs a delivery path (RESEND_API_KEY).

Tests: smoke per rule; server unit tests; full E2E suite.
