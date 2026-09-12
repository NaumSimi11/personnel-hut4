# Plan 032: People import — CSV preview, validation, atomic commit

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 (go-live) / **Effort**: M / **Risk**: MEDIUM (bulk writes) / **Depends on**: main (post-031, `d46d7ff`)
- **Category**: feature (blueprint "import preview"; a holding with existing
  staff needs its people in before day one)

## Migration 0024

- `import_people(p_company_id, p_rows jsonb, p_commit boolean)`
  (`employment.edit` in the company; SECURITY DEFINER): each row carries
  `full_name`, `work_email`, `job_title`, `start_date`, optional
  `employment_type_key`, `department`, `location`, `manager_email`,
  `preferred_name`, `phone`. Every row is validated — required fields,
  date, known type / department / location (by name, company or shared),
  manager resolved by work email (in the file or already in the company),
  duplicate email inside the file, email already on a person (refused:
  never silently merge) — and the function returns a per-row verdict.
  With `p_commit = false` nothing is written (the preview); with `true` the
  whole file is written or nothing is (one transaction): people, first
  employment (active or pre-start by date), manager links resolved after
  all rows exist. Status derived from the start date.
- Rows are capped (500 per call); the function never trusts ids from the
  client.

## App

- `lib/importPeople.ts`: CSV parsing (quoted fields, CRLF), header
  mapping (case-insensitive, a few aliases), row shaping, verdict
  summaries; unit tests.
- Directory page: **Import people** (for admins / `employment.edit`
  holders) → dialog: choose company, paste or upload CSV, preview table
  with per-row verdict (ready / refused with reason), counts, then
  Import; result summary and links.

Tests: smoke (validation verdicts, no writes on preview, atomic commit,
manager resolution inside the file, duplicate refusal), unit, E2E
`import-people.spec.ts` (CSV with three rows incl. one refused → preview
shows verdicts → import writes the two → directory shows them).
