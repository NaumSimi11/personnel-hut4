# Plan 025: Hardening — review findings across 014–019

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P0 (confidentiality) / **Effort**: S / **Risk**: LOW / **Depends on**: main (post-024, `393403b`)
- **Category**: fix (code-review findings raised during 024)

## Migration 0018

1. **Audit redaction.** `app.audit()` copied whole rows into `activity_log`,
   which `access.manage` (and, for offers, `candidates.view`) holders can
   read — so blind scorecards, compensation amounts and offer terms leaked
   past their own RLS. `app.audit_redacted(keys)` keeps identity, actors and
   status but strips the named fields; scorecards (`ratings, recommendation,
   summary`), compensation_records (`amount, note`) and offers (`terms`) now
   use it, and existing log rows are redacted in place.
2. **Cycle guard per company.** `app.would_create_cycle(person, manager,
   company)` walks the manager chain within the company; a transfer (a
   later period elsewhere) no longer hides a loop.
3. **Apply-time re-validation.** `app.validate_employment_change(period,
   changes)` holds the department / location / type / manager checks and is
   run both when scheduling and when a due change applies, so an archived
   department or a cross-company move fails with its reason instead of
   applying.
4. **One open application per candidate per job** — partial unique index.

## Server

- `RateLimiter.peek` / `record`: the per-email budget is checked before the
  work and spent only after the application is saved.
- `serialised(key, fn)`: the duplicate check and inserts run one applicant
  at a time per email; a unique-index violation maps to the same 409.

Tests: smoke (redaction, cross-company loop refused, archived department
fails at apply time, duplicate open application refused), server unit
tests, full E2E suite.
