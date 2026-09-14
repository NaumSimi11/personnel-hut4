# Plan 041: Leave manager desk and corrections

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 / **Effort**: M / **Risk**: MEDIUM (rewrites approved
  rows; the balance is derived from them) / **Depends on**: 039
- **Category**: feature, ported from Field Notebook's Manager desk (the
  deployed version — the checkout here predates its Correct dialog, so the
  rules were rebuilt from the screenshots and from what makes the balance
  honest).

## Migration 0032

- `leave_corrections`: every correction — the old picture (dates, kind,
  working days), the new one, the rows split off, note, who, when. Readable
  by the person and by leave.view / leave.approve in the company; audited
  with the note redacted.
- `leave_requests.corrected_from_id`: a row that came out of a split
  remembers its origin.
- `correct_leave(request, days, note)`: `days` is every working day the
  leave should now cover, each with its kind. Gate: leave.approve in the
  company; never one's own (platform admins excepted, as for hiring
  requests); approved rows only. Refuses non-working days, duplicates,
  unknown kinds, overlap with the person's other pending/approved leave.
  Consecutive working days of one kind form a run: the first run keeps the
  original row (id, history, documents), further runs become new approved
  rows linked back. Carry-over is re-drawn per run the way an approval
  draws it (by window, whole days). Per leave year, what the runs take from
  the year must fit what is left once this request's own days are given
  back (pending requests reserve too). Advisory lock per person.

## App

- Requests tab is the manager desk: To decide · Asks to cancel · Approved ·
  Cancelled/rejected with counts; find a person, month, company filters;
  a table for the settled record (Person · Dates · Days · Approved by, with
  "no author recorded" for imported rows), **Correct** and **Cancel** per
  approved row; corrections shown under the person ("Corrected 14 Sep by
  Naum: 2 Dec → 7 Dec · 4 annual ⟶ 2 Dec → 4 Dec · 3 annual — note").
- `CorrectLeaveDialog`: From / To, a card per working day with its kind,
  the summary line ("4 working days — the balance does not move." / "1 more
  taken from the balance." / "2 returned to Bojan."), note, "Leave it as it
  is" / "Save the correction". Holidays loaded for ±62 days so extending
  the leave counts right.
- `lib/leave`: `workingDaysInRange`, `correctionSummary`.

## Verification

- Smoke: owner refused, Saturday refused, overlap refused, empty refused;
  longer → balance −2 and a correction row; mixed kinds → two rows split off,
  sick carries requires_document, balance back; over the balance refused
  with nothing changed; own leave refused for Alex, allowed for Ada.
- Unit: `workingDaysInRange`, `correctionSummary`.
- E2E `leave.spec.ts`: approve → Approved tab → Correct → end one day later
  → summary "1 more taken" → row shows the note → balance moves → the
  employee still cancels before the start and gets it all back.
