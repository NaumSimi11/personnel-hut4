# Plan 034: Home queue — the later modules on the overview

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 (discoverability) / **Effort**: S / **Risk**: LOW / **Depends on**: main (post-033, `bbb17df`)
- **Category**: feature (blueprint §7.1 "what needs me": one queue)

## No migration

Every row comes from a table the viewer can already read; the converters
apply the same "mine to act on" rules the functions enforce, so a row is
offered only when the click can succeed.

## App

- `lib/homeQueue.ts` (pure, unit-tested): compensation proposals awaiting a
  decision (`salary.approve`, not the proposer); submitted document
  requests to review (`documents.request`); documents asked of me;
  published policies not acknowledged at their version; IT requests I can
  work (`it.assign`, or assigned to me with `it.complete`); payroll periods
  prepared by someone else awaiting my approval (`payroll.approve`).
- Home page: the queue merges these after the hiring / offers / onboarding
  rows, each with its deep link.

Tests: unit; E2E `home-queue.spec.ts` (seeded proposal, submitted request,
open IT request, colleague-prepared payroll → rows → payroll link lands
on the Payroll tab).
